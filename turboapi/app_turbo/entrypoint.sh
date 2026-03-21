#!/bin/bash
set -e

echo "Starting TurboAPI v1.0 with TurboDB..."
echo "  Host: ${UVICORN_HOST:-0.0.0.0}"
echo "  Port: ${UVICORN_PORT:-8002}"

exec /opt/python3.14t/bin/python3 -c "
import sys
import io

class FilterOutput:
    def __init__(self, output):
        self.output = output
        self.buffer = []
        
    def write(self, text):
        for char in text:
            if char == '\n':
                self._flush()
            else:
                self.buffer.append(char)
        return len(text)
    
    def _flush(self):
        if self.buffer:
            line = ''.join(self.buffer).rstrip()
            self.buffer = []
            if not line:
                return
            # Only keep these specific lines
            keep = [
                'Using pure Python',
                'Using Zig native',
                'TurboAPI: Python',
                'TurboNet-Zig server listening',
                'Zig HTTP core active',
            ]
            for k in keep:
                if k in line:
                    self.output.write(line + '\n')
                    return
    
    def flush(self):
        self._flush()
        self.output.flush()

old_stdout = sys.stdout
sys.stdout = FilterOutput(sys.stdout)

import main
main.app.run(host='${UVICORN_HOST:-0.0.0.0}', port=${UVICORN_PORT:-8002})
"
