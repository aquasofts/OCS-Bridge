import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';

// Run the upstream OCS parser and request/response pipeline without its DOM utilities.
const repo = process.argv[2] ?? '.reference/ocsjs';
const wrappers = JSON.parse(fs.readFileSync('build/ocs-wrapper.test.json', 'utf8'));
const read = name => fs.readFileSync(path.join(repo, 'packages/core/src/core/answer-wrapper', name), 'utf8');
function upstream(source, exports) {
  const js = stripTypeScriptTypes(source, { mode: 'transform' })
    .replace(/^import .*;\r?$/gm, '')
    .replace(/^export /gm, '');
  return new vm.Script(`${js}\n;({${exports}})`).runInContext(context);
}
let received;
const context = vm.createContext({
  console,
  Buffer,
  URL,
  setTimeout,
  clearTimeout,
  $: { sleep: ms => new Promise(resolve => { const timer = setTimeout(resolve, ms); timer.unref(); }) },
  request: async (url, options) => {
    received = { url, ...options };
    return { code: 0, question: options.data.title, answer: 'Dart#Python' };
  },
});
const { AnswerWrapperParser } = upstream(read('answer.wrapper.parser.ts'), 'AnswerWrapperParser');
const { defaultAnswerWrapperHandler } = upstream(read('answer.wrapper.handler.ts'), 'defaultAnswerWrapperHandler');
assert.equal(AnswerWrapperParser.fromObject(wrappers).length, 1);
const title = '以下哪些属于编程语言？';
const images = ['data:image/png;base64,AA=='];
const result = await defaultAnswerWrapperHandler(wrappers, { title, options: 'Dart\nPython', type: 'multiple', images });
assert.equal(received.url, 'http://127.0.0.1:15318/answer');
assert.equal(received.type, 'GM_xmlhttpRequest');
assert.equal(received.data.title, title);
assert.equal(received.data.type, 'multiple');
assert.equal(JSON.stringify(received.data.images), JSON.stringify(images));
assert.equal(received.headers['X-OCS-Token'], 'contract-test-token-not-for-production');
assert.equal(result[0].results[0].answer, 'Dart#Python');
assert.equal(result[0].results[0].question, title);
const handler = new Function(wrappers[0].handler)();
assert.equal(handler({ code: 0, answer: '' }), undefined);
assert.throws(() => handler({ code: 502, message: 'error' }), /error/);
console.log('OCS upstream parser + AnswerWrapper pipeline: PASS');
