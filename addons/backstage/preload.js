'use strict';
// On Node 18+, native fetch is a built-in global. Replace node-fetch 2.x with
// it via Module._load interception so cross-fetch (used by catalog-client,
// scaffolder, etc.) never creates PassThrough/Gunzip streams that
// ERR_STREAM_PREMATURE_CLOSE on Node 22.
const Module = require('module');

if (typeof globalThis.fetch === 'function') {
  const _originalLoad = Module._load.bind(Module);
  Module._load = function (request, parent, isMain) {
    if (request === 'node-fetch') {
      const nativeFetch = globalThis.fetch.bind(globalThis);
      return Object.assign(nativeFetch, {
        default: nativeFetch,
        Headers: globalThis.Headers,
        Request: globalThis.Request,
        Response: globalThis.Response,
        FetchError: class FetchError extends Error {
          constructor(msg, type, systemError) {
            super(msg);
            this.name = 'FetchError';
            this.type = type;
            this.cause = systemError;
          }
        },
        AbortError: class AbortError extends Error {
          constructor(msg) { super(msg); this.name = 'AbortError'; }
        },
      });
    }
    return _originalLoad(request, parent, isMain);
  };
}
