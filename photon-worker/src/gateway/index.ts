import type { Config } from '../config';
import { ConsoleGateway } from './console';
import type { Gateway } from './types';

export type { Gateway, InboundEvent, SendResult, TextChannel } from './types';

/** MESSAGING_GATEWAY=console|photon. Photon is imported lazily so console dev needs no credentials. */
export async function createGateway(cfg: Config): Promise<Gateway> {
  if (cfg.gateway === 'photon') {
    const { PhotonGateway } = await import('./photon');
    return new PhotonGateway({ projectId: cfg.photonProjectId, projectSecret: cfg.photonProjectSecret, line: cfg.photonLine });
  }
  return new ConsoleGateway();
}
