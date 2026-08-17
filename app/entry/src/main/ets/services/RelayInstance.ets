/**
 * Global relay client singleton + connection config.
 * Edit RELAY_URL / RELAY_TOKEN before building.
 */
import { RelayClient } from './RelayClient';

/** Relay server address. LAN: ws://<server-ip>:8787 (needs cleartext). Public: wss://... */
export const RELAY_URL: string = 'ws://192.168.31.5:8787';

/** Shared auth token — must match the relay server's DSH_RELAY_TOKEN. */
export const RELAY_TOKEN: string = 'dsh-remote-dev-token';

export const DEVICE_NAME: string = 'HarmonyOS';

/** One shared client across all pages. */
export const relay: RelayClient = new RelayClient(RELAY_URL, RELAY_TOKEN, DEVICE_NAME);
