# Mock OpenAI Responses API for a real codex (no credentials). Turn 1 of each prompt asks to run a
# command (approval needed under -a untrusted), the turn after the tool output replies with text.
import json, sys, time, uuid, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
D=os.path.dirname(os.path.abspath(__file__))
LOG=open(os.environ.get("MOCK_LOG",os.path.join(D,"mock.log")),"a"); N=[0]
SLOW=float(os.environ.get("MOCK_SLOW","0.1"))
class H(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*a): pass
    def do_GET(self):
        LOG.write("GET "+self.path+"\n"); LOG.flush()
        b=json.dumps({"data":[{"id":"mock","object":"model"}],"models":[]}).encode()
        self.send_response(200); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n=int(self.headers.get("content-length",0)); body=self.rfile.read(n)
        N[0]+=1
        if os.environ.get("MOCK_DUMP"): open(os.path.join(os.environ["MOCK_DUMP"],"req-%03d.json"%N[0]),"wb").write(body)
        try: j=json.loads(body)
        except Exception: j={}
        inp=j.get("input",[]); 
        last=inp[-1] if inp else {}
        txt=json.dumps(inp)
        LOG.write("POST %s #%d last=%s\n"%(self.path,N[0],json.dumps(last)[:300])); LOG.flush()
        self.send_response(200); self.send_header("content-type","text/event-stream"); self.send_header("connection","close"); self.end_headers()
        rid="resp_"+uuid.uuid4().hex[:8]; mid="msg_"+uuid.uuid4().hex[:8]
        def ev(t,d):
            d["type"]=t
            try: self.wfile.write(f"event: {t}\ndata: {json.dumps(d)}\n\n".encode()); self.wfile.flush()
            except Exception: pass
        ev("response.created",{"response":{"id":rid}})
        tools=[t.get("name") for t in j.get("tools",[]) if isinstance(t,dict)]
        lastuser=[x for x in inp if isinstance(x,dict) and x.get("role")=="user"]
        lu=json.dumps(lastuser[-1]) if lastuser else ""
        wants_tool = last.get("type")!="function_call_output" and last.get("type")!="custom_tool_call_output" and "RUNTOOL" in lu
        if not tools:
            # Codex's thread title request (no tools, a json_schema {title}): a short title.
            ev("response.output_item.added",{"output_index":0,"item":{"type":"message","id":mid,"role":"assistant","content":[]}})
            t=json.dumps({"title":os.environ.get("MOCK_TITLE","Create the marker file")})
            ev("response.output_text.delta",{"item_id":mid,"output_index":0,"content_index":0,"delta":t})
            ev("response.output_item.done",{"output_index":0,"item":{"type":"message","id":mid,"role":"assistant","content":[{"type":"output_text","text":t}]}})
        elif wants_tool:
            cid="call_"+uuid.uuid4().hex[:8]
            name="shell_command" if "shell_command" in tools else ("exec_command" if "exec_command" in tools else "shell")
            if name=="shell_command": args={"command":"touch made-by-codex.txt","workdir":j.get("cwd") or None}
            elif name=="exec_command": args={"cmd":"touch made-by-codex.txt"}
            else: args={"command":["bash","-lc","touch made-by-codex.txt"]}
            args={k:v for k,v in args.items() if v is not None}
            if "ESCALATE" in lu: args["sandbox_permissions"]="require_escalated"; args["justification"]="Create the marker file"
            item={"type":"function_call","id":"fc_"+cid,"call_id":cid,"name":name,"arguments":json.dumps(args)}
            ev("response.output_item.added",{"output_index":0,"item":item})
            ev("response.output_item.done",{"output_index":0,"item":item})
        else:
            ev("response.output_item.added",{"output_index":0,"item":{"type":"message","id":mid,"role":"assistant","content":[]}})
            text=""
            words=["# Result\n\n","All ","done ","here."] if "SLOWTURN" not in lu else ["w%d "%i for i in range(200)]
            for d in words:
                time.sleep(SLOW if "SLOWTURN" not in lu else 0.3); text+=d
                ev("response.output_text.delta",{"item_id":mid,"output_index":0,"content_index":0,"delta":d})
            ev("response.output_item.done",{"output_index":0,"item":{"type":"message","id":mid,"role":"assistant","content":[{"type":"output_text","text":text}]}})
        ev("response.completed",{"response":{"id":rid,"usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}})
        self.close_connection=True
s=ThreadingHTTPServer(("127.0.0.1",0),H)
open(os.environ.get("MOCK_PORT_FILE",os.path.join(D,"port")),"w").write(str(s.server_address[1]))
s.serve_forever()
