// Mock 9Router bridge. Serves just enough to drive a full sync locally,
// so the engine can be tested without the phone.
import http from 'node:http';

const PORT = Number(process.argv[2] || 20999);
// 64 hex characters, the shape a real bridge key has. The engine rejects
// anything else before it makes a request, so a short key here would make the
// mock untestable through the normal entry points.
const KEY = process.argv[3] || '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const STATUSES = {
  // Mirrors the phone: the live list lives under the singular `provider`
  // key; the plural `providers` key is the stale snapshot (deleted models
  // linger there) and must not leak back through the sync.
  opencode: {
    config: {
      providers: {
        '9router': {
          models: {
            '9router/one-day/glm-5.3-flash': {},
            'openrouter/weird#id': {},
            'ps-prefixed/model': {},
            'stale/removed': {}
          }
        }
      },
      provider: {
        '9router': {
          models: {
            '9router/one-day/glm-5.3-flash': {},
            'openrouter/weird#id': {},
            'ps-prefixed/model': {}
          }
        }
      }
    }
  },
  pi: {
    config: {
      providers: {
        '9router': {
          models: [{ id: '9router/gone/model' }, { id: 'vendor:co/dupe' }]
        }
      },
      provider: {
        '9router': {
          models: [{ id: 'vendor:co/dupe' }]
        }
      }
    }
  },
  claude: { config: null }
};

const CATALOG = {
  object: 'list',
  data: [
    { id: '9router/one-day/glm-5.3-flash', capabilities: { contextWindow: 1000000, maxOutput: 131072, vision: true, reasoning: true } },
    // tools omitted on purpose: the engine must keep tool calling enabled.
    { id: 'openrouter/weird#id', capabilities: { contextWindow: 500, maxOutput: 20, vision: 'false', reasoning: 'false', tools: 'false' } },
    { id: 'ps-prefixed/model', capabilities: { contextWindow: 8000, maxOutput: 99 } },
    { id: 'vendor:co/dupe', capabilities: { contextWindow: 4096, maxOutput: 512, tools: true } }
    // '9router/gone/model' is deliberately absent
  ]
};

const server = http.createServer((req, res) => {
  res.setHeader('content-type', 'application/json');

  // Only /api/bridge/* is behind the key. /v1/* is the inference API, which is
  // authenticated with a bearer token instead - requiring the bridge key there
  // would not match how the real 9Router behaves.
  if (req.url.startsWith('/api/bridge/')) {
    if (req.headers['x-9r-bridge-key'] !== KEY) {
      res.writeHead(401);
      res.end('{"error":"Unauthorized"}');
      return;
    }
  } else if (req.headers.authorization !== 'Bearer sk-mock-api-key') {
    res.writeHead(401);
    res.end('{"error":"bad bearer"}');
    return;
  }

  if (req.url.includes('/api/bridge/cli-tools/all-statuses')) {
    res.end(JSON.stringify(STATUSES));
  } else if (req.url.includes('/api/bridge/keys')) {
    res.end(JSON.stringify({ keys: [{ isActive: true, key: 'sk-mock-api-key' }] }));
  } else if (req.url.endsWith('/v1/models')) {
    res.end(JSON.stringify(CATALOG));
  } else if (req.url.includes('/chat/completions')) {
    res.end(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }));
  } else {
    res.writeHead(404);
    res.end('{"error":"not found"}');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock bridge on http://127.0.0.1:${PORT}`);
});