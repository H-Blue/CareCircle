"""Create/update the private Care Circle ElevenLabs agent; credentials stay in .env.

This is a setup utility. It never logs provider credentials or conversation content.
"""
import json
import os
from pathlib import Path
import urllib.request
import urllib.error

from server import load_environment

ROOT = Path(__file__).resolve().parent
PROMPT = """You are Care Circle, a calm, warm voice companion for health and everyday life.
Speak softly and gently, with a relaxed, reassuring tone and an unhurried pace. Keep your energy low and steady,
including the greeting. Avoid loud emphasis, exaggerated excitement, dramatic delivery, or a presenter voice.
Stay clear and easy to understand; use a natural speaking voice rather than whispering or sounding sleepy.
Have a real conversation. Speak naturally in one to three short sentences, respond to the person's actual words,
and remember the context. Be thoughtful and practical. Do not sound like a questionnaire, a corporate help desk,
or a therapy script. Avoid canned phrases such as 'It's totally normal' and 'It's okay to acknowledge those feelings'.
Ask at most one question, only when it moves the conversation forward. Sometimes just answer or acknowledge.
Use plain spoken language. No Markdown, asterisks, bullet lists, emoji, stage directions, or punctuation names.
For a direct request to record a doctor visit or appointment, call start_visit_recording immediately, without a
spoken preamble. The app will open its recording screen and stop this conversation. Never merely say you started
recording. Do not call it for a hypothetical question, negation or request to wait. Recording requires agreement
from everyone present; the recording screen reminds the user. You cannot access past visit recordings or health
records unless their content is explicitly provided. Never invent facts or claim unavailable actions.
Provide general health information, not diagnoses, prescriptions or medication changes. Do not recite medical
disclaimers in ordinary conversation. For immediate danger or life-threatening symptoms, direct the person to
immediate local emergency care. Do not add a follow-up question after that urgent instruction."""


def configuration():
    return {
        "name": "Care Circle",
        "conversation_config": {
            "agent": {"first_message": "Hi, I’m here. What’s on your mind?", "language": "en",
                "disable_first_message_interruptions": False,
                "prompt": {"prompt": PROMPT, "llm": "gemini-3.8-flash", "temperature": 0.5,
                    "max_tokens": 300, "ignore_default_personality": True,
                    "tools": [{"type": "client", "name": "start_visit_recording",
                        "description": "Open the native doctor-visit recorder when the user directly asks to begin recording or transcribing their visit. Never for negations, hypothetical questions, or without a user request.",
                        "expects_response": False, "pre_tool_speech": "off", "execution_mode": "immediate",
                        "parameters": {"type": "object", "properties": {}, "required": []}}]}},
            "asr": {"quality": "high", "provider": "scribe_realtime", "user_input_audio_format": "pcm_16000"},
            "tts": {"model_id": "eleven_v3_conversational", "voice_id": "SAz9YHcvj6GT2YYXdXww",
                    "expressive_mode": True, "speed": 0.9, "agent_output_audio_format": "pcm_16000"},
            "turn": {"turn_eagerness": "normal", "turn_timeout": 7, "turn_model": "turn_v3"},
            "conversation": {"max_duration_seconds": 1800,
                "client_events": ["audio", "interruption", "user_transcript", "agent_response", "agent_response_correction", "client_tool_call"]},
        },
        "platform_settings": {
            "auth": {"enable_auth": True},
            "privacy": {"record_voice": False, "retention_days": 1, "delete_transcript_and_pii": True, "delete_audio": True},
            "call_limits": {"agent_concurrency_limit": 1, "daily_limit": 30, "bursting_enabled": False},
        },
    }


def main():
    path = ROOT / ".env"
    load_environment(path)
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        raise SystemExit("Add the restricted ElevenLabs key to the private Server/.env first.")
    agent = os.environ.get("ELEVENLABS_AGENT_ID")
    url = "https://api.elevenlabs.io/v1/convai/agents/" + (agent if agent else "create")
    request = urllib.request.Request(url, data=json.dumps(configuration()).encode(), method="PATCH" if agent else "POST",
                                     headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        # Validation errors only describe this non-sensitive agent configuration.
        if error.code == 422:
            print(error.read().decode()[:2500])
        raise SystemExit(f"ElevenLabs agent setup failed (HTTP {error.code}).") from None
    agent = agent or result["agent_id"]
    lines = [line for line in path.read_text().splitlines() if not line.startswith("ELEVENLABS_AGENT_ID=")]
    path.write_text("\n".join(lines) + "\nELEVENLABS_AGENT_ID=" + agent + "\n")
    path.chmod(0o600)
    print("Private Care Circle agent configured:", agent)
    print("Audio recording disabled; transcript retention is one day. Single concurrent conversation; 30 sessions/day.")


if __name__ == "__main__":
    main()
