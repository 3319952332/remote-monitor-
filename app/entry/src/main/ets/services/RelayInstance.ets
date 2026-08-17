/**
 * Global relay client singleton.
 * Connection config is injected by gen-relay-config.mjs into RelayConfig.ets
 * (source: relay-config.local.json, which is gitignored). Never hardcode real
 * URL/token here.
 */
import { RelayClient } from './RelayClient';
import { RELAY_URL, RELAY_TOKEN } from './RelayConfig';

export const DEVICE_NAME: string = 'HarmonyOS';

/** One shared client across all pages. */
export const relay: RelayClient = new RelayClient(RELAY_URL, RELAY_TOKEN, DEVICE_NAME);
