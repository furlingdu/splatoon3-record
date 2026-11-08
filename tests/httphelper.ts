import { createServer, type RequestListener } from 'node:http';

interface HttpTestServer {
  url: string;
  close: () => Promise<void>;
}

export interface HttpTestServers {
  listen: (handler: RequestListener) => Promise<string>;
  closeAll: () => Promise<void>;
}

export function createHttpServers(): HttpTestServers {
  const servers: HttpTestServer[] = [];
  return {
    async listen(handler) {
      const server = await listenHttp(handler);
      servers.push(server);
      return server.url;
    },
    async closeAll() {
      await Promise.all(servers.splice(0).map((server) => server.close()));
    },
  };
}

function listenHttp(handler: RequestListener): Promise<HttpTestServer> {
  return new Promise((resolve) => {
    const server = createServer(handler);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port = typeof address === 'object' && address ? address.port : 0;
      resolve({
        url: `http://127.0.0.1:${port}`,
        close: () => new Promise<void>((done) => server.close(() => done())),
      });
    });
  });
}
