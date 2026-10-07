import { existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const modelFile = join(root, 'runtime', 'models', 'spld_v2_nickname.onnx');

function checkModel() {
  if (!existsSync(modelFile)) throw new Error('缺少推理模型 runtime/models/spld_v2_nickname.onnx');
  return statSync(modelFile).size;
}

const size = checkModel();
console.log(`runtime 就绪：模型 ${size} 字节`);
