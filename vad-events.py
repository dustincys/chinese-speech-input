import sounddevice as sd
import numpy as np
import torch
import sys
from datetime import datetime, timedelta

SILENCE_DURATION = 500
SAMPLING_RATE = 16000
CHUNK_SIZE = 512
model, utils = torch.hub.load(repo_or_dir='snakers4/silero-vad',
                              model='silero_vad',
                              force_reload=False)

(get_speech_timestamps, save_audio, read_audio, VADIterator, collect_chunks) = utils
vad_iterator = VADIterator(model, threshold=0.5, min_silence_duration_ms=SILENCE_DURATION)

stream_start_time = None

def format_iso_with_offset(offset_seconds):
    if stream_start_time is None:
        return "PENDING"
    event_time = stream_start_time + timedelta(seconds=offset_seconds)
    return event_time.astimezone().isoformat(timespec='milliseconds')

def audio_callback(indata, frames, time, status):
    global stream_start_time
    if status:
        print(status, file=sys.stderr)
    if stream_start_time is None:
        stream_start_time = datetime.now()
    tensor_input = torch.from_numpy(indata.copy()).flatten()
    speech_dict = vad_iterator(tensor_input, return_seconds=True)
    if speech_dict:
        if "start" in speech_dict:
            print(f"START {format_iso_with_offset(speech_dict['start'])}", flush=True)
        if "end" in speech_dict:
            print(f"END {format_iso_with_offset(speech_dict['end'])}", flush=True)
try:
    with sd.InputStream(samplerate=SAMPLING_RATE,
                        channels=1,
                        callback=audio_callback,
                        blocksize=CHUNK_SIZE):
        while True:
            pass
except KeyboardInterrupt:
    print("\nStopping...")
