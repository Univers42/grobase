// MessageActions.tsx — the action bar of the reading pane: Close / Reopen / Archive.
// Each mutation toasts on success or failure; the parent supplies the status setter.

import { Button } from '../../ds/Button';
import { Icon } from '../../ds/Icon';
import { useToast } from '../../providers/useToast';
import type { Message, MessageStatus } from './message';

/** MessageActionsProps wires the active message and the status mutation. */
export type MessageActionsProps = {
  message: Message;
  onStatus: (id: string, status: MessageStatus) => Promise<void>;
};

/** MessageActions renders the status controls, toasting the outcome of each. */
export function MessageActions({ message, onStatus }: MessageActionsProps) {
  const toast = useToast();

  async function apply(status: MessageStatus, done: string) {
    try {
      await onStatus(message.id, status);
      toast.success(done);
    } catch (e: unknown) {
      toast.error('Action failed', e instanceof Error ? e.message : undefined);
    }
  }

  return (
    <div className="flex flex-wrap gap-2">
      {message.status === 'open' ? (
        <Button variant="secondary" size="sm" onClick={() => apply('closed', 'Message closed')}>
          <Icon name="check" size={14} /> Close
        </Button>
      ) : (
        <Button variant="secondary" size="sm" onClick={() => apply('open', 'Message reopened')}>
          <Icon name="arrowRight" size={14} /> Reopen
        </Button>
      )}
      <Button variant="ghost" size="sm" onClick={() => apply('archived', 'Message archived')}>
        <Icon name="close" size={14} /> Archive
      </Button>
    </div>
  );
}
