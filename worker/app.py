import os, socket, time
from fastapi import FastAPI, Response
from pydantic import BaseModel
from threading import BoundedSemaphore

app = FastAPI()
WORKER_ID = socket.gethostname()
MAX_CONCURRENCY = int(os.getenv('MAX_CONCURRENCY', '1'))
WORK_MS = int(os.getenv('WORK_MS', '450'))
slots = BoundedSemaphore(MAX_CONCURRENCY)

class Job(BaseModel):
    job_id: str

@app.get('/health')
def health():
    return {'status': 'ok', 'worker_id': WORKER_ID}

@app.post('/job')
def job(req: Job, response: Response):
    if not slots.acquire(blocking=False):
        response.status_code = 503
        return {'job_id': req.job_id, 'status': 'busy', 'worker_id': WORKER_ID}
    try:
        time.sleep(WORK_MS / 1000.0)
        return {'job_id': req.job_id, 'status': 'completed', 'worker_id': WORKER_ID}
    finally:
        slots.release()
