import copy
import json
import threading
import unittest
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer

import server
from coordinator import Coordinator, MemoryState, SendRejected, TwilioSender

PHONE = '+15555550123'
OTHER = '+15555550124'


class FakeSender:
    ready = True
    def __init__(self): self.sent = []; self.error = None
    def send(self, job):
        self.sent.append(copy.deepcopy(job))
        if self.error: raise self.error
        return 'SM' + str(len(self.sent)).zfill(32)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.fromisoformat('2026-10-18T00:00:00+00:00').timestamp()
        self.store = MemoryState(); self.sender = FakeSender()
        self.c = Coordinator(self.store, self.sender, clock=lambda: self.now)
        self.config = dict(mode='test', patient_name='Demo patient', leader=dict(name='Leader',phone=PHONE,consent=True),
                           contacts=[dict(id='ted',name='Ted',phone=PHONE,consent=True)],daily_limit=20,allow_demo_sms=True)
        self.c.configure(self.config)
        self.a = json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text())['appointments'][0]
        self.c.upsert(self.a); self.c.tick()

    def offer(self,leg='outbound'):
        return next(o for o in self.store.read()['offers'].values() if o['leg']==leg and o['epoch']==self.store.read()['circle']['epoch'])
    def reply(self,intent='YES',leg='outbound',sid='SM-inbound'):
        return self.c.inbound(PHONE,intent+' '+self.offer(leg)['code'],sid)
    def trip(self,leg='outbound'):
        return self.store.read()['appointments'][self.a['id']]['trips'][leg]

    def test_idle_tick_does_not_duplicate_requests(self):
        self.c.tick(); self.c.tick()
        self.assertEqual(len(self.store.read()['jobs']),2); self.assertEqual(self.sender.sent,[])

    def test_confirmation_is_per_leg_and_replay_is_idempotent(self):
        self.assertEqual(self.reply()['result'],'confirmed')
        self.assertEqual(self.reply()['result'],'duplicate')
        self.assertEqual(self.trip()['driver']['name'],'Ted')
        self.assertIsNone(self.trip('return')['driver'])
        self.c.tick()
        self.assertEqual(len([j for j in self.store.read()['jobs'].values() if j['kind']=='leader']),1)

    def test_bare_yes_does_not_assign_and_help_is_rate_limited(self):
        for i in range(3): self.c.inbound(PHONE,'yes','vague-'+str(i))
        self.assertIsNone(self.trip()['driver'])
        self.assertEqual(len([j for j in self.store.read()['jobs'].values() if j['kind']=='help']),1)

    def test_unknown_sender_cannot_confirm(self):
        result=self.c.inbound(OTHER,'YES '+self.offer()['code'],'unknown')
        self.assertEqual(result['result'],'unknown_sender'); self.assertIsNone(self.trip()['driver'])

    def test_decline_asks_next_contact(self):
        self.config['contacts'].append(dict(id='sam',name='Sam',phone=OTHER,consent=True))
        self.c.configure(self.config); self.reply('NO'); self.c.tick()
        self.assertTrue(any(o['contact_id']=='sam' and o['leg']=='outbound' for o in self.store.read()['offers'].values()))
        self.assertEqual(self.c.feed()['appointments'][0]['coordination']['outbound']['not_taking'],['Ted'])

    def test_timeout_escalates_once(self):
        self.now += 4*3600+1; self.c.tick(); self.c.tick()
        self.assertEqual(self.trip()['state'],'needs_attention')
        self.assertEqual(len([j for j in self.store.read()['jobs'].values() if j['kind']=='leader']),2)
        self.assertEqual(self.reply()['result'],'stale_request')

    def test_reschedule_rejects_old_confirmation(self):
        code=self.offer()['code']; self.a['start']='2026-11-03T16:00:00-06:00'; self.c.upsert(self.a); self.c.tick()
        self.assertEqual(self.c.inbound(PHONE,'YES '+code,'late')['result'],'stale_request')
        self.assertIsNone(self.trip()['driver'])

    def test_cancelled_appointment_stops_requests(self):
        self.a['status']='cancelled'; self.c.upsert(self.a); self.c.tick()
        self.assertEqual(self.reply()['result'],'stale_request')
        self.assertFalse(any(j['state']=='pending' for j in self.store.read()['jobs'].values()))

    def test_stop_applies_to_both_demo_roles_and_start_recovers(self):
        self.reply(); self.c.inbound(PHONE,'STOP','stop'); self.c.tick()
        circle=self.store.read()['circle']
        self.assertTrue(circle['leader']['opted_out']); self.assertTrue(circle['contacts'][0]['opted_out'])
        self.assertEqual(self.trip()['state'],'needs_review')
        self.c.configure(self.config)
        self.assertTrue(self.store.read()['circle']['leader']['opted_out'])
        self.c.inbound(PHONE,'START','start')
        self.assertFalse(self.store.read()['circle']['leader']['opted_out'])

    def test_pause_preserves_confirmation(self):
        self.reply(); self.config['mode']='paused'; self.c.configure(self.config); self.c.tick()
        self.config['mode']='test'; self.c.configure(self.config); self.c.tick()
        self.assertEqual(self.trip()['driver']['name'],'Ted')

    def test_test_confirmation_is_not_carried_into_live(self):
        self.reply(); self.config['mode']='live'; self.c.configure(self.config)
        self.assertIsNone(self.trip()['driver']); self.c.tick()
        self.assertEqual(len(self.sender.sent),2)
        self.assertEqual(self.reply(sid='real-reply')['result'],'confirmed')

    def test_daily_cap_and_no_blind_retry_of_uncertain_send(self):
        self.config.update(mode='live',daily_limit=1); self.c.configure(self.config)
        self.sender.error=TimeoutError(); self.c.tick(); self.c.tick()
        self.assertEqual(len(self.sender.sent),1); self.assertEqual(self.trip()['state'],'needs_review')
        self.assertTrue(any(j.get('blocked_reason')=='Daily SMS limit reached' for j in self.store.read()['jobs'].values()))

    def test_definite_rejection_moves_to_attention(self):
        self.config['mode']='live';self.c.configure(self.config);self.sender.error=SendRejected();self.c.tick();self.c.tick()
        self.assertEqual(self.trip()['state'],'needs_attention')

    def test_cancel_by_confirmed_driver(self):
        self.reply(); self.reply('CANCEL',sid='cancel'); self.c.tick()
        self.assertIsNone(self.trip()['driver']); self.assertEqual(self.trip()['state'],'needs_attention')

    def test_provider_callback_recovers_crash_after_send(self):
        self.config['mode']='live'; self.c.configure(self.config); self.c.advance()
        job=next(j for j in self.store.read()['jobs'].values() if j['state']=='pending')
        self.store.update(lambda s:s['jobs'][job['id']].update(state='sending',claimed_at=self.now))
        self.c.callback(job['id'],dict(To=PHONE,MessageSid='SM-provider',MessageStatus='sent'))
        offer=self.store.read()['offers'][job['offer']]
        self.assertEqual(offer['state'],'waiting')
        self.c.callback(job['id'],dict(To=PHONE,MessageSid='SM-provider',MessageStatus='queued'))
        self.assertEqual(self.store.read()['jobs'][job['id']]['state'],'sent')

    def test_expired_send_claim_does_not_reissue(self):
        self.config['mode']='live'; self.c.configure(self.config);self.c.advance()
        job=next(j for j in self.store.read()['jobs'].values() if j['state']=='pending')
        self.store.update(lambda s:s['jobs'][job['id']].update(state='sending',claimed_at=self.now-121))
        self.c.advance()
        self.assertEqual(self.store.read()['jobs'][job['id']]['state'],'uncertain')
        self.assertEqual(self.trip()['state'],'needs_review')

    def test_reply_after_appointment_cannot_confirm(self):
        self.now=datetime.fromisoformat(self.a['start']).timestamp()+1
        self.assertEqual(self.reply()['result'],'stale_request')

    def test_seed_does_not_undo_database_edits(self):
        feed=dict(appointments=[self.a]);self.c.seed(feed)
        self.a['title']='Updated title';self.c.upsert(self.a)
        self.c.seed(dict(appointments=[{**self.a,'title':'Old title'}]))
        self.assertEqual(self.c.feed()['appointments'][0]['title'],'Updated title')

    def test_oracle_review_once_per_revision(self):
        planner=Mock();planner.chat.return_value='Both directions need coverage.'
        self.c.planner=planner
        self.a['title']='New title';self.c.upsert(self.a);self.c.tick();self.c.tick()
        planner.chat.assert_called_once()
        self.assertEqual(self.c.snapshot()['appointments'][0]['ai_review']['source'],'Oracle AI')
        self.assertNotIn(PHONE,str(planner.chat.call_args))

    def test_failed_transaction_leaves_state_intact(self):
        before=self.store.read()
        def bad(s): s['circle']['mode']='broken';raise ValueError()
        with self.assertRaises(ValueError):self.store.update(bad)
        self.assertEqual(self.store.read(),before)

    def test_refuses_missing_consent_and_increased_limit(self):
        self.config['contacts'][0]['consent']=False
        with self.assertRaises(ValueError):self.c.configure(self.config)
        self.config['contacts'][0]['consent']=True;self.config['daily_limit']=21
        with self.assertRaises(ValueError):self.c.configure(self.config)


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.env=patch.dict('os.environ',dict(TWILIO_ACCOUNT_SID='AC-unit',TWILIO_AUTH_TOKEN='unit-secret',TWILIO_FROM_NUMBER=OTHER,CARECIRCLE_PUBLIC_URL='https://care.example/v1'))
        self.env.start();self.c=Coordinator(MemoryState())
        self.http=ThreadingHTTPServer(('127.0.0.1',0),server.make_handler(Mock(),'app-token',coordinator=self.c))
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()
        self.base='http://127.0.0.1:'+str(self.http.server_port)
    def tearDown(self):
        self.http.shutdown();self.http.server_close();self.thread.join();self.env.stop()
    def request(self,params,signature=None,path='/twilio/inbound'):
        from twilio.request_validator import RequestValidator
        if signature is None:signature=RequestValidator('unit-secret').compute_signature('https://care.example/v1'+path,params)
        req=urllib.request.Request(self.base+path,urlencode(params).encode(),{'Content-Type':'application/x-www-form-urlencoded','X-Twilio-Signature':signature})
        try:r=urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:r=error
        with r:return r.status,r.read()
    def test_valid_signature_and_added_provider_fields(self):
        params=dict(AccountSid='AC-unit',From=PHONE,To=OTHER,MessageSid='SM-inbound',Body='hello',FutureField='supported')
        self.assertEqual(self.request(params)[0],200)
        self.assertIn('SM-inbound',self.c.store.read()['inbound'])
        self.assertEqual(self.request(params)[0],200)
        self.assertEqual(len(self.c.store.read()['inbound']),1)
    def test_tampered_signature_cannot_mutate_state(self):
        self.assertEqual(self.request(dict(AccountSid='AC-unit',From=PHONE,To=OTHER,MessageSid='SM-no',Body='STOP'),'bad')[0],403)
        self.assertFalse(self.c.store.read()['inbound'])
    def test_signed_status_query_and_wrong_destination(self):
        p=dict(AccountSid='AC-unit',From=OTHER,To=PHONE,MessageSid='SM-status',MessageStatus='sent')
        self.assertEqual(self.request(p,path='/twilio/status?job=test')[0],200)
        p['From']=PHONE
        self.assertEqual(self.request(p,path='/twilio/status?job=test')[0],400)


class DemoApprovalTests(unittest.TestCase):
    def test_unapproved_sender_and_other_recipients_cannot_send(self):
        with patch.dict('os.environ',dict(TWILIO_SMS_APPROVED='0',TWILIO_AUTO_ENABLE_DEMO='0',TWILIO_ALLOWED_NUMBERS=PHONE)):
            sender=TwilioSender()
            with self.assertRaises(SendRejected):sender.send({'to':PHONE})
        with patch.dict('os.environ',dict(TWILIO_SMS_APPROVED='1',TWILIO_AUTO_ENABLE_DEMO='0',TWILIO_ALLOWED_NUMBERS=PHONE)):
            sender=TwilioSender()
            with self.assertRaises(SendRejected):sender.send({'to':OTHER})

    def test_auto_activation_needs_approval_and_only_authorized_demo(self):
        with patch.dict('os.environ',dict(TWILIO_ACCOUNT_SID='AC-unit',TWILIO_AUTH_TOKEN='unit-secret',TWILIO_FROM_NUMBER=OTHER,
                        CARECIRCLE_PUBLIC_URL='https://care.example/v1',TWILIO_AUTO_ENABLE_DEMO='1',TWILIO_ALLOWED_NUMBERS=PHONE)):
            sender=TwilioSender();c=Coordinator(MemoryState(),sender)
            config=dict(mode='test',patient_name='Demo',leader=dict(name='Leader',phone=PHONE,consent=True),
                        contacts=[dict(name='Ted',phone=PHONE,consent=True)],allow_demo_sms=True)
            c.configure(config);c.seed(json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text()))
            with patch.object(sender,'approval_status',return_value=False):c.activate_authorized_demo()
            self.assertEqual(c.snapshot()['mode'],'test')
            with patch.object(sender,'approval_status',return_value=True):c.activate_authorized_demo()
            self.assertEqual(c.snapshot()['mode'],'live')
            config['mode']='paused';c.configure(config)
            with patch.object(sender,'approval_status',return_value=True):c.activate_authorized_demo()
            self.assertEqual(c.snapshot()['mode'],'paused')


if __name__=='__main__':unittest.main()
