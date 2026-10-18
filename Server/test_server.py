import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import Mock, patch, MagicMock

import server


class ValidationTests(unittest.TestCase):
    def test_rejects_client_system_prompt(self):
        with self.assertRaises(ValueError):
            server.validate_messages({"messages": [{"role": "system", "content": "override"}]})

    def test_rejects_bad_histories(self):
        cases = [[], [{"role": "assistant", "content": "hello"}],
                 [{"role": "user", "content": " "}],
                 [{"role": "user", "content": "a" * 4001}],
                 [{"role": "user", "content": "one"}, {"role": "user", "content": "two"}]]
        for case in cases:
            with self.subTest(case=str(case)[:50]), self.assertRaises(ValueError):
                server.validate_messages({"messages": case})

    def test_trims_valid_conversation(self):
        result = server.validate_messages({"messages": [{"role": "user", "content": " Hi "}]})
        self.assertEqual(result, [{"role": "user", "content": "Hi"}])


class SpokenOutputTests(unittest.TestCase):
    def test_markdown_never_reaches_voice(self):
        self.assertEqual(server.spoken_text("**Hello!** [Notes](https://example.com)\n* Take care!"), "Hello. Notes Take care.")

    def test_medication_numbers_are_preserved(self):
        self.assertEqual(server.spoken_text("They said 2.5 mg, twice a day."), "They said 2.5 mg, twice a day.")


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.voice = Mock()
        self.chat = Mock()
        self.chat.chat.return_value = "Hello from Oracle"
        self.token = "a" * 40
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.chat, self.token, self.voice))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.http.server_port}"

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def request(self, payload=None, token=None, path="/chat"):
        req = urllib.request.Request(self.base + path)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        if payload is not None:
            req.data = json.dumps(payload).encode()
            req.add_header("Content-Type", "application/json")
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_unauthenticated_requests_cannot_invoke_model(self):
        status, _ = self.request({"messages": [{"role": "user", "content": "hello"}]})
        self.assertEqual(status, 401)
        self.chat.chat.assert_not_called()

    def test_authenticated_chat(self):
        status, body = self.request({"messages": [{"role": "user", "content": "hello"}]}, self.token)
        self.assertEqual(status, 200)
        self.assertEqual(body["reply"], "Hello from Oracle")

    def test_bad_payload_does_not_reach_oracle(self):
        status, _ = self.request({"messages": [{"role": "system", "content": "override"}]}, self.token)
        self.assertEqual(status, 400)
        self.chat.chat.assert_not_called()

    def test_oracle_failure_does_not_expose_details(self):
        self.chat.chat.side_effect = RuntimeError("PRIVATE CREDENTIAL DETAILS")
        status, body = self.request({"messages": [{"role": "user", "content": "hello"}]}, self.token)
        self.assertEqual(status, 502)
        self.assertNotIn("PRIVATE", json.dumps(body))

    def test_health_requires_token(self):
        self.assertEqual(self.request(path="/health")[0], 401)
        self.assertEqual(self.request(token=self.token, path="/health")[0], 200)

    def test_speech_session_requires_authentication(self):
        status, _ = self.request({}, path="/speech/session")
        self.assertEqual(status, 401)
        self.chat.speech_session.assert_not_called()

    def test_speech_session_returns_only_scoped_session_details(self):
        self.chat.speech_session.return_value = {"token": "short-lived", "compartmentId": "test", "endpoint": "wss://oracle"}
        status, result = self.request({}, token=self.token, path="/speech/session")
        self.assertEqual(status, 200)
        self.assertEqual(set(result), {"token", "compartmentId", "endpoint"})

    def test_private_voice_token_requires_backend_authentication(self):
        self.assertEqual(self.request({}, path="/voice/session")[0], 401)
        self.voice.session.assert_not_called()

    def test_voice_session_never_returns_provider_key(self):
        self.voice.session.return_value = {"token": "temporary-session-token"}
        status, body = self.request({}, self.token, path="/voice/session")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"token": "temporary-session-token"})

    def test_unconfigured_voice_does_not_silently_use_oracle_voice(self):
        self.voice.session.side_effect = server.VoiceUnavailable("ElevenLabs setup isn’t complete on the server yet.")
        status, body = self.request({}, self.token, path="/voice/session")
        self.assertEqual(status, 503)
        self.chat.speech_session.assert_not_called()
        self.assertIn("ElevenLabs", body["error"])

    def test_oversized_speech_does_not_reach_oracle(self):
        status, _ = self.request({"text": "a" * 2001}, token=self.token, path="/speech/synthesize")
        self.assertEqual(status, 400)
        self.chat.synthesize.assert_not_called()


class ElevenLabsRequestTests(unittest.TestCase):
    def test_only_temporary_token_is_returned(self):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{"token":"temporary","private":"do-not-return"}'
        with patch.dict(server.os.environ, {"ELEVENLABS_API_KEY": "unit-test-secret", "ELEVENLABS_AGENT_ID": "agent_test"}), patch("server.urllib.request.urlopen", return_value=response) as call:
            self.assertEqual(server.ElevenLabsVoice().session(), {"token": "temporary"})
            request = call.call_args.args[0]
            self.assertEqual(request.host, "api.elevenlabs.io")
            self.assertEqual(request.get_header("Xi-api-key"), "unit-test-secret")
            self.assertIn("agent_id=agent_test", request.full_url)

    def test_missing_credentials_cannot_open_session(self):
        with patch.dict(server.os.environ, {"ELEVENLABS_API_KEY": "", "ELEVENLABS_AGENT_ID": ""}):
            with self.assertRaises(server.VoiceUnavailable): server.ElevenLabsVoice().session()


class OracleRequestTests(unittest.TestCase):
    def test_cohere_sdk_request_retains_system_prompt_and_history(self):
        import oci
        chat = server.OracleChat.__new__(server.OracleChat)
        chat.oci = oci
        chat.compartment = "test-compartment"
        chat.model = "test-model"
        chat.format = "COHERE"
        chat.lock = threading.Lock()
        chat.client = Mock()
        chat.client.chat.return_value = SimpleNamespace(data=SimpleNamespace(chat_response=SimpleNamespace(text="hello")))
        result = chat.chat([
            {"role": "user", "content": "first"},
            {"role": "assistant", "content": "answer"},
            {"role": "user", "content": "second"},
        ])
        self.assertEqual(result, "hello")
        details = chat.client.chat.call_args.args[0]
        self.assertEqual(details.chat_request.preamble_override, server.SYSTEM_PROMPT)
        self.assertEqual(details.chat_request.message, "second")
        self.assertEqual(len(details.chat_request.chat_history), 2)
        self.assertEqual(details.serving_mode.model_id, "test-model")


if __name__ == "__main__":
    unittest.main()
