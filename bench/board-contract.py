#!/usr/bin/env python3
"""Real shared CLI -> Go HTTP -> SQLite board contract, with no external providers."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    env = dict(os.environ, SYMPHONY_GO_MODE='fixture', SYMPHONY_PROJECT='demo',
               SYMPHONY_DEMO_TOKEN=secrets.token_hex(32), SYMPHONY_DEMO_DB=temporary+'/state.sqlite',
               SYMPHONY_GO_ADDR=f'127.0.0.1:{port}', SYMPHONY_URL=f'http://127.0.0.1:{port}')
    binary = os.environ.get('SYMPHONY_GO_BINARY', str(ROOT/'bench/go-manual'))
    process = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def cli(*args):
        result = subprocess.run(['python3',str(ROOT/'cli/symphonyctl'),*args,'--json'],env=env,text=True,capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)
    try:
        for attempt in range(100):
            try:
                board=cli('tasks','board')
                break
            except AssertionError:
                if process.poll() is not None: raise
                time.sleep(.05)
        else: raise AssertionError('server startup timeout')
        task=cli('tasks','create','--title','CLI-created task','--project','second-label','--revision',str(board['board_revision']))
        task_id=task['id']
        def mutate(action,*args):
            current=cli('tasks','show',task_id)
            return cli('tasks',action,task_id,'--revision',str(current['revision']),*args)
        mutate('move','--stage','Todo')
        mutate('plan','--text','Inspect\nValidate')
        mutate('check','--step','1','--completed','true')
        mutate('worklog','--plan-text','Parent\n  Child','--acceptance-text','Reviewed','--validation-text','Synthetic checks')
        comment=mutate('comment','--text','Review from CLI')
        mutate('comment','--text','Reply','--parent-id',comment['id'])
        mutate('link','--kind','pull_request','--title','Synthetic reference','--url','https://example.com/pull/1')
        artifact=Path(temporary)/'artifact.json'
        artifact.write_text(json.dumps({'reference':'synthetic-check','summary':'A fixture observation, not real agent output'}))
        revision=str(cli('tasks','show',task_id)['revision'])
        args=('tasks','import-agent',task_id,'--revision',revision,'--key','offline-replay','--file',str(artifact))
        first=cli(*args)
        artifact.unlink()
        assert cli(*args)==first, 'receipt recovery read missing artifact'
        task=cli('tasks','show',task_id)
        assert task['plan'][1]['completed'] and len(task['comments'])==2 and len(task['documents'])==1 and len(task['reports'])==1
        assert task['release_verified'] is False and len(cli('tasks','list','--project','second-label'))==1
        assert cli('tasks','show','fixture-1')['revision']==1, 'cross-task mutation'
        assert all(event['task_id']==task_id for event in cli('tasks','history',task_id))
        print('PASS: real shared CLI create/move/plan/check/worklog/comment/link/import, offline receipt replay, project filter and task isolation')
    finally:
        process.terminate()
        process.wait(timeout=10)
