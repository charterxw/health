import http.client
import json
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch, MagicMock

from app.media_bridge import MediaBridge, MediaRecognition, BridgeError, validate_result


class Stream:
    def __init__(self, events):self.events = events
    def __enter__(self):return iter(self.events)
    def __exit__(self, *args):pass


class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5);self.sock.connect(self.host)


class MediaBridgeTests(unittest.TestCase):
    def test_model_stream_contract_and_complete_result(self):
        recognition = MediaRecognition('x'*40)
        client = MagicMock()
        events = [NS(type='response.output_text.delta', delta=json.dumps({'title': '冰菓', 'year': '2012', 'media_type': 'tv'})),
                  NS(type='response.completed', response=NS(usage=NS(input_tokens=30, output_tokens=20, total_tokens=50)))]
        client.responses.create.return_value = Stream(events)
        with patch('app.media_bridge.OpenAI', return_value=client) as factory, patch('app.media_bridge.get_access_token', return_value='private-test-token'):
            response = recognition.recognize({'kind': 'extract', 'data': {'files': ['Hyouka.S01E01.mkv']}})
        self.assertEqual(response['result']['title'], '冰菓')
        self.assertEqual(response['usage']['total_tokens'], 50)
        args = client.responses.create.call_args.kwargs
        self.assertFalse(args['store']);self.assertTrue(args['stream']);self.assertNotIn('tools', args)
        self.assertTrue(args['text']['format']['strict']);self.assertFalse(recognition.lock.locked())
        factory.assert_called_once();client.close.assert_called_once()

    def test_partial_stream_and_quota_never_produce_success(self):
        recognition = MediaRecognition('x'*40);client = MagicMock()
        for events, expected in [([NS(type='response.output_text.delta', delta='{"ok":true}')], 502),
                                  ([NS(type='response.failed', response=NS(error={'code': 'subscription_sharing_usage_limit_exceeded'}))], 429)]:
            client.responses.create.return_value = Stream(events)
            with patch('app.media_bridge.OpenAI', return_value=client), patch('app.media_bridge.get_access_token', return_value='token'):
                with self.assertRaises(BridgeError) as caught:recognition.recognize({'kind': 'health', 'data': {}})
            self.assertEqual(caught.exception.status, expected);self.assertFalse(recognition.lock.locked())

    def test_rank_is_bound_to_real_tmdb_candidates(self):
        with self.assertRaises(BridgeError):
            validate_result('rank', {'id': 999, 'reason': 'invented'}, {'candidates': [{'id': 1}]})

    def test_unix_socket_requires_token_and_exposes_no_credentials(self):
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='ai-') as temporary:
            path = Path(temporary);token = path/'token';token.write_text('x'*40)
            bridge = MediaBridge(path/'s', token)
            try:
                for authorization, expected in [('',401), ('Bearer '+'x'*40,200)]:
                    conn = UnixConnection(str(path/'s'))
                    with patch('app.media_bridge.is_chatgpt_connected', return_value=True):
                        conn.request('GET','/status', headers={'Authorization': authorization})
                        response = conn.getresponse();result = json.loads(response.read())
                    self.assertEqual(response.status, expected)
                    self.assertNotIn('access_token', result);self.assertNotIn('refresh_token', result)
                    if expected == 200:self.assertTrue(result['connected'])
                    conn.close()
            finally:bridge.close()


if __name__ == '__main__':unittest.main()
