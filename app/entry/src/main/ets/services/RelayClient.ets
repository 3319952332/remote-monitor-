/**
 * Relay WebSocket client: dials the relay server, performs the hello
 * handshake, exposes typed request/response, and fans events out to a
 * callback. Handles heartbeat + reconnect.
 *
 * ArkTS note: uses @ohos.net.webSocket (system WebSocket). For plain ws:// on
 * LAN the app must allow cleartext traffic (see app/README.md); for wss:// a
 * real CA cert is required — HarmonyOS trusts the system store, not self-signed.
 */
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  RelayFrame,
  WelcomeFrame,
  ErrorFrame,
  ResponseFrame,
  EventFrame,
  HeartbeatFrame,
  HelloFrame,
  RequestFrame,
  RelayError,
  EmptyParams,
} from '../model/Protocol';

const PROTOCOL_VERSION = 1;

export class RelayClient {
  private url: string;
  private token: string;
  private deviceName: string;
  private ws: webSocket.WebSocket | null = null;
  private connected: boolean = false;
  private closed: boolean = false;
  private seq: number = 0;
  private pending: Map<string, (r: ResponseFrame) => void> = new Map<string, (r: ResponseFrame) => void>();
  private reconnectTimer: number = -1;
  private heartbeatTimer: number = -1;
  private backoffMs: number = 1000;

  /** Fired for every relayed event: (event, sessionId, data). */
  onEvent: (event: string, sessionId: string, data: object) => void = () => {};
  /** Fired when connection state changes: (online, detail). */
  onStatus: (online: boolean, detail: string) => void = () => {};

  constructor(url: string, token: string, deviceName: string) {
    this.url = url;
    this.token = token;
    this.deviceName = deviceName;
  }

  /** Start the connection (idempotent). */
  connect(): void {
    this.closed = false;
    this.open();
  }

  private open(): void {
    if (this.closed || this.ws !== null) {
      return;
    }
    let ws: webSocket.WebSocket;
    try {
      ws = webSocket.createWebSocket();
    } catch (e) {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.on('open', (_err: BusinessError, _value: Object) => {
      this.connected = true;
      this.backoffMs = 1000;
      this.onStatus(true, '已连接');
      this.sendHello();
      this.startHeartbeat();
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        return;
      }
      const text: string = typeof value === 'string' ? value : '';
      this.handleMessage(text);
    });

    ws.on('close', (_err: BusinessError, _value: Object) => {
      this.teardown('连接已断开');
    });

    ws.on('error', (_err: BusinessError) => {
      this.teardown('连接错误');
    });

    ws.connect(this.url, (err: BusinessError) => {
      if (err) {
        this.teardown(`连接失败: ${err.message}`);
      }
    });
  }

  private sendHello(): void {
    const frame: HelloFrame = {
      v: PROTOCOL_VERSION,
      type: 'hello',
      role: 'client',
      token: this.token,
      deviceName: this.deviceName,
      platform: 'harmonyos',
    };
    this.sendFrame(frame);
  }

  private handleMessage(text: string): void {
    let frame: RelayFrame;
    try {
      frame = JSON.parse(text) as RelayFrame;
    } catch (e) {
      return;
    }
    switch (frame.type) {
      case 'welcome': {
        const w = frame as WelcomeFrame;
        this.onStatus(true, `节点在线 (${w.id.slice(0, 8)})`);
        break;
      }
      case 'response': {
        const resp = frame as ResponseFrame;
        const cb = this.pending.get(resp.id ?? '');
        if (cb) {
          this.pending.delete(resp.id ?? '');
          cb(resp);
        }
        break;
      }
      case 'event': {
        const ev = frame as EventFrame;
        const data: object = ev.data !== undefined ? ev.data : {} as EmptyParams;
        this.onEvent(ev.event, ev.sessionId ?? '', data);
        break;
      }
      case 'ping': {
        const p = frame as HeartbeatFrame;
        const pong: HeartbeatFrame = { v: PROTOCOL_VERSION, type: 'pong', t: p.t };
        this.sendFrame(pong);
        break;
      }
      case 'pong':
        break;
      case 'error': {
        const e = frame as ErrorFrame;
        this.onStatus(false, `错误: ${e.message}`);
        break;
      }
      default:
        break;
    }
  }

  /** Send a method request and resolve with the matching response. */
  request(method: string, params: object, nodeId?: string): Promise<ResponseFrame> {
    return new Promise<ResponseFrame>((resolve) => {
      const id = `req-${++this.seq}`;
      this.pending.set(id, resolve);
      const frame: RequestFrame = { v: PROTOCOL_VERSION, type: 'request', id, method, params };
      if (nodeId) {
        frame.nodeId = nodeId;
      }
      this.sendFrame(frame);
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          const err: RelayError = { code: 'TIMEOUT', message: `${method} 无响应` };
          const resp: ResponseFrame = { v: PROTOCOL_VERSION, type: 'response', id, ok: false, error: err };
          resolve(resp);
        }
      }, 30000);
    });
  }

  private sendFrame(frame: object): void {
    if (this.ws !== null && this.connected) {
      try {
        this.ws.send(JSON.stringify(frame), (_err: BusinessError) => {});
      } catch (e) {
        // ignore
      }
    }
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
    }
    this.heartbeatTimer = setInterval(() => {
      if (this.connected) {
        const ping: HeartbeatFrame = { v: PROTOCOL_VERSION, type: 'ping', t: Date.now() };
        this.sendFrame(ping);
      }
    }, 30000);
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer !== -1) {
      return;
    }
    this.onStatus(false, `${Math.round(this.backoffMs / 1000)}s 后重连`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.backoffMs = Math.min(this.backoffMs * 2, 30000);
      this.open();
    }, this.backoffMs);
  }

  private teardown(detail: string): void {
    if (this.ws !== null) {
      try {
        this.ws.close((_err: BusinessError) => {});
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
    this.connected = false;
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    // Fail all in-flight requests so callers don't hang.
    const err: RelayError = { code: 'DISCONNECTED', message: detail };
    this.pending.forEach((cb, id) => {
      const resp: ResponseFrame = { v: PROTOCOL_VERSION, type: 'response', id, ok: false, error: err };
      cb(resp);
    });
    this.pending.clear();
    this.onStatus(false, detail);
    if (!this.closed) {
      this.scheduleReconnect();
    }
  }

  /** Permanently stop (no reconnect). */
  close(): void {
    this.closed = true;
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.teardown('已关闭');
  }
}
