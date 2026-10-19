
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", os.environ["GATE"])
gate = importlib.util.module_from_spec(spec); sys.modules["gate"]=gate; spec.loader.exec_module(gate)
api = gate.GitHubAPI(os.environ["REPO"], os.environ["GH_TOKEN"])
posted=[]
api.create_commit_status = lambda sha,d: posted.append((sha,d.state,d.description))
d = gate.evaluate_pr(api, int(os.environ["PR"]))
pr = gate.GitHubAPI(os.environ["REPO"], os.environ["GH_TOKEN"]).get_pull_request(int(os.environ["PR"]))
head, merge = pr["head"]["sha"], (pr.get("merge_commit_sha") or "")
print("decision:", d.state if d else None, "|", (d.description[:50] if d else ""))
for sha,state,desc in posted:
    tag = "HEAD" if sha==head else ("test-merge" if sha==merge else "other")
    print(f"   {tag:10} {sha[:10]} {state}")
