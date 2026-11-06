#!/usr/bin/env python3
"""End-to-end tests against the running Jarvis app (/Applications/Jarvis.app).

Plays the Claude side over the real MCP server (`VoiceBrowser --mcp`) and drives Jarvis through the
bridge's /hear route, as if the user had spoken. Needs Jarvis and Ollama running.
Jarvis speaks the answers out loud while this runs.

    python3 -I tests/e2e_bridge.py
"""
import json
import pathlib
import subprocess
import threading
import time
import unittest
import urllib.request

EXE = "/Applications/Jarvis.app/Contents/MacOS/VoiceBrowser"
CFG = json.loads((pathlib.Path.home() / "Library/Application Support/Jarvis/bridge.json").read_text())


def bridge(method, path, body=None, timeout=120):
    req = urllib.request.Request(CFG["url"] + path, json.dumps(body).encode() if body is not None else None,
                                 {"Authorization": "Bearer " + CFG["token"], "Content-Type": "application/json"},
                                 method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        return json.loads(data) if data else {}


def hear(text):
    return bridge("POST", "/hear", {"text": text})["reply"]


class MCP:
    """A minimal MCP client over stdio, standing in for Claude."""

    def __init__(self):
        self.p = subprocess.Popen([EXE, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0
        self.lock = threading.Lock()
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "e2e", "version": "1"}})

    def rpc(self, method, params=None):
        with self.lock:
            self.n += 1
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
            self.p.stdin.flush()
            return json.loads(self.p.stdout.readline())

    def tool(self, name, **args):
        r = self.rpc("tools/call", {"name": name, "arguments": args})["result"]
        return r["content"][0]["text"], r.get("isError", False)

    def close(self):
        self.p.stdin.close()
        self.p.wait(5)


def live_claude_connected():
    """A real Claude session is already serving Jarvis (it would take requests before our stand-in)."""
    return bridge("GET", "/status").get("agent_waiting") == "yes"


def serve_one(mcp, answer, got):
    """Claude side: wait for one request and answer it."""
    text, _ = mcp.tool("jarvis_wait_for_request", wait_seconds=30)
    got["req"] = json.loads(text)
    mcp.tool("jarvis_answer", id=got["req"]["id"], text=answer)


class JarvisE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mcp = MCP()

    @classmethod
    def tearDownClass(cls):
        cls.mcp.close()

    def test_mcp_lists_all_tools(self):
        names = {t["name"] for t in self.mcp.rpc("tools/list")["result"]["tools"]}
        self.assertTrue({"jarvis_wait_for_request", "jarvis_answer", "jarvis_command", "jarvis_context",
                         "jarvis_screenshot", "jarvis_shell"} <= names)

    def test_offline_answer(self):
        reply = hear("ask locally what is the capital of australia")
        self.assertIn("canberra", reply.lower())

    def test_claude_answer_over_mcp(self):
        if live_claude_connected():
            reply = hear("Claude, what is the tallest mountain in Africa")
            self.assertIn("kilimanjaro", reply.lower(), "answered by the live Claude session")
            return
        got = {}
        t = threading.Thread(target=serve_one, args=(self.mcp, "Mount Kilimanjaro.", got))
        t.start()
        time.sleep(1)  # Claude is waiting before Jarvis asks
        reply = hear("Claude, what is the tallest mountain in Africa")
        t.join()
        self.assertEqual(got["req"]["kind"], "ask")
        self.assertEqual(got["req"]["text"], "what is the tallest mountain in africa")
        self.assertIn("front_app", got["req"]["context"])
        self.assertEqual(got["req"]["context"].get("full_control"), "off")
        self.assertEqual(reply, "Mount Kilimanjaro.")

    def test_claude_runs_a_jarvis_command(self):
        text, err = self.mcp.tool("jarvis_command", text="what time is it")
        self.assertFalse(err)
        self.assertIn("It's", json.loads(text)["result"])

    def test_command_refuses_questions(self):
        text, _ = self.mcp.tool("jarvis_command", text="why is the sky blue")
        self.assertIn("error", json.loads(text))

    def test_full_control_tools_refused_when_off(self):
        text, _ = self.mcp.tool("jarvis_shell", command="echo hi")
        self.assertIn("Full Control is off", text)

    def test_bridge_cannot_grant_full_control(self):
        reply = hear("give Claude full control")
        self.assertIn("only be turned on by voice", reply)
        status, _ = self.mcp.tool("jarvis_status")
        self.assertTrue(json.loads(status)["full_control"].startswith("off"))

    def test_draft_reply_from_clipboard(self):
        saved = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
        message = "Hi Sam, can we move tomorrow's call to 4pm? Thanks, Ana"
        subprocess.run(["pbcopy"], input=message, text=True)
        try:
            if live_claude_connected():
                reply = hear("draft a reply saying 4pm works")
                self.assertIn("Here's a draft", reply)
                self.assertIn("haven't sent", reply)
                clip = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
                self.assertNotEqual(clip, message, "the draft replaced the message on the clipboard")
                self.assertIn("4", clip)
                return
            got = {}
            t = threading.Thread(target=serve_one, args=(self.mcp, "Hi Ana, 4pm works for me. See you then!", got))
            t.start()
            time.sleep(1)
            reply = hear("draft a reply saying 4pm works")
            t.join()
            self.assertEqual(got["req"]["kind"], "draft")
            self.assertIn("4pm", got["req"]["context"].get("conversation", ""))
            self.assertIn("Here's a draft", reply)
            self.assertIn("haven't sent", reply)
            clip = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
            self.assertEqual(clip, "Hi Ana, 4pm works for me. See you then!")
        finally:
            subprocess.run(["pbcopy"], input=saved, text=True)


class MemoryAndAgentsE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mcp = MCP()

    @classmethod
    def tearDownClass(cls):
        cls.mcp.close()

    def test_list_methods_for_other_agents(self):
        # Antigravity / Cursor ask for resources and prompts too; they must get empty lists, not errors.
        self.assertEqual(self.mcp.rpc("resources/list")["result"], {"resources": []})
        self.assertEqual(self.mcp.rpc("prompts/list")["result"], {"prompts": []})

    def test_remember_recall_forget_by_voice(self):
        fact = "my e2e test colour is ultramarine"
        self.assertIn("remember", hear("remember that " + fact).lower())
        found, _ = self.mcp.tool("jarvis_memory", query="ultramarine")
        self.assertIn("ultramarine", json.loads(found)["facts"])
        self.assertIn("ultramarine", hear("what do you remember about me").lower())
        self.assertIn("forgotten", hear("forget that").lower())
        found, _ = self.mcp.tool("jarvis_memory", query="ultramarine")
        self.assertNotIn("ultramarine", json.loads(found)["facts"])

    def test_agent_can_remember(self):
        self.mcp.tool("jarvis_remember", fact="E2E agent fact: tea over coffee")
        found, _ = self.mcp.tool("jarvis_memory", query="coffee")
        self.assertIn("tea over coffee", json.loads(found)["facts"])
        hear("forget that")

    def test_requests_are_logged_with_history_in_context(self):
        hear("what time is it")
        ctx, _ = self.mcp.tool("jarvis_context")
        self.assertIn("what time is it", json.loads(ctx).get("recent_history", ""))


VOICE = "http://127.0.0.1:8765"


def voice_server_up():
    try:
        return urllib.request.urlopen(VOICE + "/v1/models", timeout=2).status == 200
    except Exception:
        return False


@unittest.skipUnless(voice_server_up(), "Creator Studio's voice server isn't running (Jarvis menu → Voice → Start…)")
class VoiceServerE2E(unittest.TestCase):
    """Jarvis's voice and Whisper go through Creator Studio's mlx-audio server."""

    def speak(self, text, voice="bm_george"):
        req = urllib.request.Request(VOICE + "/v1/audio/speech", json.dumps({
            "model": "mlx-community/Kokoro-82M-bf16", "input": text, "voice": voice, "lang_code": "b",
            "speed": 1.0, "response_format": "wav"}).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()

    def test_kokoro_speech(self):
        wav = self.speak("Opening YouTube.")
        self.assertEqual(wav[:4], b"RIFF")
        self.assertGreater(len(wav), 10_000)

    def test_whisper_transcribes_a_command(self):
        wav = self.speak("Hey Jarvis, open GitHub.")
        boundary = "e2e"
        body = b"".join([
            f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nmlx-community/whisper-large-v3-turbo-asr-fp16\r\n'.encode(),
            f'--{boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\nen\r\n'.encode(),
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="c.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode(),
            wav, f"\r\n--{boundary}--\r\n".encode()])
        req = urllib.request.Request(VOICE + "/v1/audio/transcriptions", body,
                                     {"Content-Type": f"multipart/form-data; boundary={boundary}"})
        t = time.time()
        with urllib.request.urlopen(req, timeout=180) as r:
            text = json.load(r)["text"].lower()
        print(f"\n    Whisper heard: {text!r} in {time.time() - t:.1f}s")
        self.assertIn("jarvis", text)
        self.assertIn("github", text)

    def test_jarvis_uses_the_voice_server(self):
        status = bridge("GET", "/status")
        log = status.get("recent_log", "")
        self.assertNotIn("failed", log.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
