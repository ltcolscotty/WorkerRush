#!/usr/bin/env python3
import json, os, subprocess, sys, time
mode=sys.argv[1] if len(sys.argv)>1 else 'practice'
duration=600 if mode=='scored' else 120
credits=100.0
burn_per_task_per_sec=0.018
samples=[]
start=time.time()
def aws(*args):
    p=subprocess.run(['aws',*args,'--output','json'],capture_output=True,text=True)
    return json.loads(p.stdout or '{}') if p.returncode==0 else {}
cluster=os.environ['CLUSTER_NAME']; service=os.environ['SERVICE_NAME']; tg=os.environ['TG_ARN']
while time.time()-start < duration:
    s=aws('ecs','describe-services','--cluster',cluster,'--services',service).get('services',[{}])[0]
    desired=s.get('desiredCount',0); running=s.get('runningCount',0); pending=s.get('pendingCount',0)
    h=aws('elbv2','describe-target-health','--target-group-arn',tg).get('TargetHealthDescriptions',[])
    healthy=sum(x.get('TargetHealth',{}).get('State')=='healthy' for x in h)
    credits=max(0,credits-running*burn_per_task_per_sec*2)
    elapsed=int(time.time()-start); left=max(0,duration-elapsed)
    samples.append({'t':elapsed,'desired':desired,'running':running,'pending':pending,'healthy':healthy,'credits':credits})
    print(f'\rTime {left//60:02d}:{left%60:02d} | desired {desired} | running {running} | healthy {healthy} | credits {credits:5.1f}',end='',flush=True)
    time.sleep(2)
print()
with open('/tmp/game-monitor.json','w') as f: json.dump({'credits':credits,'samples':samples},f)
