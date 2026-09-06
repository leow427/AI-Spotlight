#!/usr/bin/env python3
"""Verify native Codex file-tool isolation against a loopback fixture provider.

No account, cloud inference, or user file contents are used. Set
AI_SPOTLIGHT_CODEX_PATH to probe a specific installed app-server version.
"""

import http.server
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

codex_path = os.environ.get('AI_SPOTLIGHT_CODEX_PATH') or shutil.which('codex')
if not codex_path:
    raise SystemExit('Install Codex or set AI_SPOTLIGHT_CODEX_PATH first.')

code_mode = '--code-mode' in sys.argv
code_source = """
if (typeof process !== "undefined" || typeof require !== "undefined" || typeof fetch !== "undefined") {
  throw new Error("Unexpected host IO globals");
}
const allowed = new Set(["read_file", "request_user_input", "skills__list", "skills__read"]);
const unexpected = ALL_TOOLS.map(tool => tool.name).filter(name => !allowed.has(name));
if (unexpected.length) throw new Error("Unexpected tools: " + unexpected.join(","));
let blocked = false;
try { await import("node:fs"); } catch { blocked = true; }
if (!blocked) throw new Error("Node filesystem imports must be unavailable");
text("ISOLATED_TOOL_RUNNER_VERIFIED");
text(await tools.read_file({path: "fixture.txt"}));
"""

captures=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        data=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        captures.append(data)
        if len(captures)==1:
            item={'type':'function_call','id':'fc_1','call_id':'call_1','name':'read_file','arguments':'{"path":"fixture.txt"}'}
            if code_mode:
                item={'type':'custom_tool_call','id':'fc_1','call_id':'call_1','name':'exec','input':code_source}
        else:
            item={'type':'message','id':'msg_1','role':'assistant','status':'completed','content':[{'type':'output_text','text':'Fixture read.','annotations':[]}]}
        response={'id':'resp_'+str(len(captures)),'object':'response','status':'completed','output':[item],
                  'usage':{'input_tokens':10,'output_tokens':10,'total_tokens':20}}
        events=[{'type':'response.created','response':{**response,'status':'in_progress','output':[]}},
                {'type':'response.output_item.added','output_index':0,'item':item},
                {'type':'response.output_item.done','output_index':0,'item':item},
                {'type':'response.completed','response':response}]
        content=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(content))); self.end_headers(); self.wfile.write(content)

with tempfile.TemporaryDirectory(prefix='ai-codex-probe-') as directory:
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    config=['model_provider="fixture"','model_providers.fixture.name="Fixture"',
      f'model_providers.fixture.base_url="http://127.0.0.1:{server.server_port}/v1"',
      'model_providers.fixture.wire_api="responses"','model_providers.fixture.requires_openai_auth=false',
      'features.shell_tool=false','features.unified_exec=false','features.apps=false','features.plugins=false',
      'features.remote_plugin=false','features.hooks=false','features.multi_agent=false','features.browser_use=false',
      'features.computer_use=false','features.view_image=false','features.image_generation=false',
      'features.shell_snapshot=false','features.skill_search=false','features.skip_host_skill_discovery=true',
      'features.workspace_dependencies=false','features.code_mode=false','features.code_mode_host=false',
      'features.artifact=false','features.memories=false','features.tool_suggest=false','features.goals=false',
      'features.enable_request_compression=false','web_search="disabled"','project_doc_max_bytes=0']
    if code_mode:
        config += ['features.code_mode=true', 'features.code_mode_only=true', 'features.code_mode_host=true']
    args=[codex_path,'app-server','--listen','stdio://']
    for value in config: args+=['-c',value]
    process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
      text=True,cwd=directory,env={'HOME':directory,'CODEX_HOME':directory,'PATH':'/usr/bin:/bin:/opt/homebrew/bin'})
    inbox=queue.Queue()
    def read():
        for line in process.stdout:
            try: inbox.put(json.loads(line))
            except ValueError: pass
    threading.Thread(target=read,daemon=True).start()
    def send(value): process.stdin.write(json.dumps(value)+'\n'); process.stdin.flush()
    def receive(expected):
        deadline=time.monotonic()+35
        while time.monotonic()<deadline:
            message=inbox.get(timeout=max(0.1,deadline-time.monotonic()))
            if message.get('id')==expected:
                if 'error' in message: raise RuntimeError(message['error'])
                return message.get('result')
    try:
        send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'file_probe','version':'1'},'capabilities':{'experimentalApi':True}}}); receive(1)
        send({'method':'initialized'})
        send({'id':2,'method':'thread/start','params':{'model':'gpt-5.1-codex','modelProvider':'fixture','ephemeral':True,
          'cwd':directory,'sandbox':'workspace-write','approvalPolicy':'untrusted','environments':[],
          'dynamicTools':[{'type':'function','name':'read_file','description':'Read an attached file','inputSchema':{
            'type':'object','properties':{'path':{'type':'string'}},'required':['path'],'additionalProperties':False}}]}})
        thread=receive(2)['thread']['id']
        send({'id':3,'method':'turn/start','params':{'threadId':thread,'environments':[],
          'input':[{'type':'text','text':'Read fixture.txt using read_file.'}],
          'sandboxPolicy':{'type':'workspaceWrite','writableRoots':[directory],'networkAccess':False,
            'excludeSlashTmp':True,'excludeTmpdirEnvVar':True}}})
        receive(3)
        deadline=time.monotonic()+45; calls=0
        while time.monotonic()<deadline:
            message=inbox.get(timeout=max(0.1,deadline-time.monotonic()))
            if message.get('method')=='item/tool/call':
                calls+=1
                assert message['params']['tool']=='read_file'
                send({'id':message['id'],'result':{'success':True,'contentItems':[{'type':'inputText','text':'Fixture contents'}]}})
            if message.get('method')=='turn/completed':
                assert message['params']['turn']['status']=='completed',message
                break
        else: raise RuntimeError('No completed turn')
        offered=[(tool.get('type'),tool.get('name')) for tool in captures[0]['tools']]
        print(json.dumps({'native_tool_calls':calls,'provider_requests':len(captures),'offered_tools':offered},indent=2))
        unsafe={'exec_command','shell','shell_command','write_stdin','view_image','read_file','apply_patch',
          'filesystem','terminal','computer','browser'}
        assert calls==1 and len(captures)==2
        assert any(item.get('type') in {'function_call_output', 'custom_tool_call_output'} and 'Fixture contents' in str(item.get('output'))
                   for item in captures[1].get('input', [])), 'Tool output did not reach the next model step'
        assert all(name not in unsafe or (name=='read_file' and kind=='function') for kind,name in offered)
        if code_mode:
            assert 'ISOLATED_TOOL_RUNNER_VERIFIED' in json.dumps(captures[1].get('input', []))
        print('NATIVE CODEX FILE TOOL CONTRACT PASSED' + (' (isolated code mode)' if code_mode else ' (direct tools)'))
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        server.shutdown()
