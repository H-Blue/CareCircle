import copy
import json
import os
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

import server
import sms_consent
from coordinator import Coordinator, MemoryState

PHONE = '+15555550123'


class ConsentTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {'TWILIO_ALLOWED_NUMBERS': PHONE})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.sender=Mock(ready=True);self.sender.send.return_value='SM-sent'
        self.store=MemoryState();self.c=Coordinator(self.store,self.sender)
        self.config=dict(mode='test',patient_name='Demo patient',leader=dict(name='Owner',phone=PHONE,consent=True),
                         contacts=[dict(name='Demo friend',phone=PHONE,consent=True)],allow_demo_sms=True)
        self.c.configure(self.config)
        self.payload=dict(action='accept',name='Test Owner',phone=PHONE,accepted=True,version=sms_consent.VERSION)
    def test_blank_consent_starts_inactive_and_unchecked(self):
        info=self.c.consent_info()
        self.assertFalse(info['active']);self.assertIsNone(info['receipt'])
        self.assertIn('STOP',info['disclosure']);self.assertIn('HELP',info['disclosure'])
        self.assertIn('not a condition',info['disclosure']);self.assertIn('rates may apply',info['disclosure'])
    def test_explicit_acceptance_records_server_time_text_and_source(self):
        info=self.c.save_sms_consent(self.payload)
        self.assertTrue(info['active'])
        record=self.store.read()['sms_consents'][PHONE]
        self.assertEqual(record['disclosure'],sms_consent.DISCLOSURE)
        self.assertEqual(record['source'],'ios_app');self.assertTrue(record['accepted_at'])
        self.assertEqual(record['name'],'Test Owner')
    def test_missing_checkbox_stale_version_and_other_phone_rejected(self):
        for change in [dict(accepted=False),dict(accepted='true'),dict(version='old'),dict(phone='+15555550124'),dict(name=''),dict(name='Injected\nname')]:
            with self.subTest(change=change),self.assertRaises(ValueError):self.c.save_sms_consent({**self.payload,**change})
        self.assertFalse(self.store.read().get('sms_consents'))
    def test_formatted_us_phone_normalizes_to_allowlist(self):
        self.c.save_sms_consent({**self.payload,'phone':'(555) 555-0123'})
        self.assertTrue(self.c.consent_info()['active'])
    def test_repeat_identical_submission_is_idempotent(self):
        a=self.c.save_sms_consent(self.payload);b=self.c.save_sms_consent(self.payload)
        self.assertEqual(a['receipt']['id'],b['receipt']['id'])
        self.assertEqual(len(self.store.read()['sms_consent_events']),1)
    def test_consent_persists_in_fresh_coordinator_instance(self):
        self.c.save_sms_consent(self.payload)
        other=Coordinator(self.store,self.sender)
        self.assertTrue(other.consent_info()['active'])
    def test_live_dispatch_waits_for_consent_then_sends(self):
        self.config['mode']='live';self.c.configure(self.config)
        self.c.seed(json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text()));self.c.tick()
        self.sender.send.assert_not_called()
        self.assertTrue(all(j.get('blocked_reason')=='In-app SMS consent required' for j in self.store.read()['jobs'].values()))
        self.c.save_sms_consent(self.payload);self.c.tick()
        self.assertEqual(self.sender.send.call_count,6)
    def test_withdrawal_suppresses_queue_and_preserves_receipt(self):
        self.c.save_sms_consent(self.payload)
        self.c.seed(json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text()));self.c.advance()
        self.c.save_sms_consent(dict(action='withdraw',phone=PHONE))
        info=self.c.consent_info();self.assertFalse(info['active']);self.assertTrue(info['receipt']['revoked_at'])
        self.assertTrue(all(j['state']=='suppressed' for j in self.store.read()['jobs'].values()))
        self.assertTrue(all(not p['consent'] for p in self.store.read()['circle']['contacts']))
    def test_withdrawn_confirmed_ride_requires_review(self):
        self.c.save_sms_consent(self.payload)
        self.c.seed(json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text()));self.c.tick()
        offer=next(iter(self.store.read()['offers'].values()))
        self.c.inbound(PHONE,'YES '+offer['code'],'SM-confirm')
        self.c.save_sms_consent(dict(action='withdraw',phone=PHONE))
        trip=self.store.read()['appointments'][offer['appointment_id']]['trips'][offer['leg']]
        self.assertEqual(trip['state'],'needs_review');self.assertIsNotNone(trip['driver'])
    def test_acceptance_does_not_clear_provider_stop(self):
        self.c.inbound(PHONE,'STOP','SM-stop');self.c.save_sms_consent(self.payload)
        self.assertTrue(self.c.consent_info()['opted_out_by_sms'])
    def test_reacceptance_has_new_receipt_and_does_not_revive_stale_offers(self):
        first=self.c.save_sms_consent(self.payload)
        self.c.seed(json.loads((Path(__file__).parent/'fixtures/appointments.json').read_text()));self.c.tick()
        old=next(iter(self.store.read()['offers'].values()))
        self.c.save_sms_consent(dict(action='withdraw',phone=PHONE))
        new=self.c.save_sms_consent(self.payload);self.c.tick()
        self.assertNotEqual(first['receipt']['id'],new['receipt']['id'])
        self.assertEqual(self.c.inbound(PHONE,'YES '+old['code'],'SM-old')['result'],'stale_request')


class ConsentHTTPTests(unittest.TestCase):
    def setUp(self):
        self.env=patch.dict(os.environ,{'TWILIO_ALLOWED_NUMBERS':PHONE});self.env.start();self.addCleanup(self.env.stop)
        self.c=Coordinator(MemoryState(),sender=Mock(ready=True))
        self.c.configure(dict(mode='test',patient_name='Demo',leader=dict(name='Owner',phone=PHONE,consent=True),contacts=[dict(name='Friend',phone=PHONE,consent=True)]))
        self.http=ThreadingHTTPServer(('127.0.0.1',0),server.make_handler(Mock(),'private-test-token',coordinator=self.c))
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()
    def tearDown(self):self.http.shutdown();self.http.server_close();self.thread.join()
    def request(self,auth=False,payload=None):
        headers={'Content-Type':'application/json'}
        if auth:headers['Authorization']='Bearer private-test-token'
        req=urllib.request.Request('http://127.0.0.1:'+str(self.http.server_port)+'/sms/consent',None if payload is None else json.dumps(payload).encode(),headers)
        try:r=urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:r=e
        with r:return r.status,json.load(r)
    def test_no_public_read_or_write(self):
        self.assertEqual(self.request()[0],401)
        self.assertEqual(self.request(payload=dict(action='accept'))[0],401)
    def test_authenticated_accept_get_withdraw(self):
        self.assertFalse(self.request(auth=True)[1]['active'])
        p=dict(action='accept',name='Owner',phone=PHONE,accepted=True,version=sms_consent.VERSION)
        self.assertEqual(self.request(auth=True,payload=p)[0],200)
        self.assertTrue(self.request(auth=True)[1]['active'])
        self.assertFalse(self.request(auth=True,payload=dict(action='withdraw',phone=PHONE))[1]['active'])
    def test_invalid_submission_cannot_record_consent(self):
        self.assertEqual(self.request(auth=True,payload=dict(action='accept',phone=PHONE))[0],400)
        self.assertFalse(self.c.consent_info()['active'])

if __name__=='__main__':unittest.main()
