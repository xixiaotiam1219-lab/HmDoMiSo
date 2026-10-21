import { worker } from '@kit.ArkTS';
import { SynthPreview } from '../core/SynthPreview';
import { ScoreResult } from '../core/Score';

interface RenderCommand { type: string; score: string; path: string; }
const port = worker.workerPort;
port.onmessage = (event) => {
  const command = event.data as RenderCommand;
  if (command.type !== 'render') { return; }
  const score = JSON.parse(command.score) as ScoreResult;
  new SynthPreview().render(score, command.path, (value: number) => {
    port.postMessage({type: 'progress', progress: value});
  }).then(() => { port.postMessage({type: 'ready'}); })
    .catch((e: Error) => { port.postMessage({type: 'error', text: e.message}); });
};
