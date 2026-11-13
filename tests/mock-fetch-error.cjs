'use strict';

const mode = process.env.ZENTAO_SMOKE_ERROR_MODE || 'unavailable';

function response(body, cookies) {
  return {
    headers: {
      getSetCookie() { return cookies || []; },
      get() { return null; },
    },
    async text() { return body; },
  };
}

global.fetch = async (url, options = {}) => {
  if (mode === 'wrong-password') {
    const parsed = new URL(url);
    if (parsed.searchParams.get('f') === 'login' && (options.method || 'GET') === 'GET') {
      return response("<input name='verifyRand' value='12345'>", ['zentaosid=smoke;']);
    }
    if (parsed.searchParams.get('f') === 'login' && options.method === 'POST') {
      return response('{}', []);
    }
  }
  throw new Error('connect ECONNREFUSED mock');
};
