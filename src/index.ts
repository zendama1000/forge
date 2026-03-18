/**
 * Brand Toolkit Server Entry Point
 * ポート3001でREST APIを提供
 */
import app from './app';

const PORT = Number(process.env.PORT ?? 3001);
const HOST = process.env.HOST ?? '0.0.0.0';

const server = app.listen(PORT, HOST, () => {
  console.log(`Brand Toolkit API server listening on http://${HOST}:${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  server.close(() => {
    console.log('Server shut down gracefully');
    process.exit(0);
  });
});

export { app, server };
