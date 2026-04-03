import app from './app';

const PORT = parseInt(process.env.PORT ?? '3001', 10);
const HOST = process.env.HOST ?? '0.0.0.0';

const server = app.listen(PORT, HOST, () => {
  console.log(`[Server] Sales Letter Service running on http://localhost:${PORT}`);
  console.log(`[Server] Health check: http://localhost:${PORT}/api/health`);
});

server.on('error', (err: NodeJS.ErrnoException) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[Server] Port ${PORT} is already in use`);
  } else {
    console.error('[Server] Failed to start:', err.message);
  }
  process.exit(1);
});

export default server;
