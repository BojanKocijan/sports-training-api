// Node < 22 has no native WebSocket, which @supabase/realtime-js requires even though this
// API never uses realtime subscriptions. Polyfill only when it's actually missing.
if (typeof globalThis.WebSocket === 'undefined') {
  const { WebSocket } = await import('ws')
  // @ts-expect-error - ws's types don't perfectly match the lib.dom WebSocket type
  globalThis.WebSocket = WebSocket
}
