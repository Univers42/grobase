import { useState, useCallback } from 'react';
import { motion } from 'framer-motion';
import { MessageSquare, Mail, Reply, Archive, Eye, Send, Trash2 } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import useBaasRealtime from '@/hooks/useBaasRealtime';
import baas from '@/baas/client';
import Modal from '@/components/ui/Modal';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

const STATUS_CONFIG = {
  unread:   { color: 'bg-amber/15 text-amber-dark',        icon: Mail,    label: 'Unread' },
  read:     { color: 'bg-blue-100 text-blue-700',          icon: Eye,     label: 'Read' },
  replied:  { color: 'bg-green-100 text-green-700',        icon: Reply,   label: 'Replied' },
  archived: { color: 'bg-gray-100 text-gray-600',          icon: Archive, label: 'Archived' },
};

export default function AdminMessages() {
  const [filter, setFilter] = useState('all');

  const filters = filter !== 'all' ? { status: filter } : {};
  const { data: messages, loading, refetch } = useBaasCollection('visitor_messages', {
    filters,
    order: 'created_at.desc',
    limit: 50,
  });

  // Real-time: auto-refresh when a new message arrives
  useBaasRealtime('visitor_messages', 'insert', useCallback(() => {
    refetch();
  }, [refetch]));

  // ── Reply state ─────────────────────────────────────────
  const [replying, setReplying] = useState(null);
  const [replyText, setReplyText] = useState('');
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(null);

  const markAs = async (id, status) => {
    try {
      await baas.collection('visitor_messages').eq('id', id).update({ status, updated_at: new Date().toISOString() });
      refetch();
    } catch (err) {
      alert(`Failed to update message: ${err.message}`);
    }
  };

  const openReply = (msg) => {
    setReplying(msg);
    setReplyText(msg.reply || '');
  };

  const sendReply = async () => {
    if (!replying || !replyText.trim()) return;
    setSaving(true);
    try {
      await baas.collection('visitor_messages').eq('id', replying.id).update({
        reply: replyText.trim(),
        status: 'replied',
        replied_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
      setReplying(null);
      setReplyText('');
      refetch();
    } catch (err) {
      alert(`Failed to send reply: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async () => {
    if (!deleting) return;
    setSaving(true);
    try {
      await baas.collection('visitor_messages').eq('id', deleting.id).remove();
      setDeleting(null);
      refetch();
    } catch (err) {
      alert(`Error: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="font-display text-2xl font-bold text-forest">Visitor Messages</h2>
          <p className="text-sm text-charcoal/50">Contact form submissions · {messages?.length ?? 0} messages</p>
        </div>
      </div>

      {/* Status filter */}
      <div className="flex gap-2">
        {['all', 'unread', 'read', 'replied', 'archived'].map((s) => (
          <button
            key={s}
            onClick={() => setFilter(s)}
            className={`rounded-full px-4 py-2 text-xs font-medium transition ${
              filter === s
                ? 'bg-forest text-ivory'
                : 'bg-white text-charcoal/60 hover:bg-sand/60'
            }`}
          >
            {s === 'all' ? 'All' : STATUS_CONFIG[s]?.label || s}
          </button>
        ))}
      </div>

      {loading && <p className="text-charcoal/40">Loading messages…</p>}

      <div className="space-y-3">
        {messages?.map((msg, i) => {
          const cfg = STATUS_CONFIG[msg.status] || STATUS_CONFIG.unread;
          const StatusIcon = cfg.icon;

          return (
            <motion.div
              key={msg.id}
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: Math.min(i * 0.03, 0.3) }}
              className={`card p-5 ${msg.status === 'unread' ? 'border-l-4 border-amber' : ''}`}
            >
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-medium text-forest">{msg.subject}</h3>
                    <span className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold ${cfg.color}`}>
                      <StatusIcon className="h-3 w-3" />
                      {cfg.label}
                    </span>
                  </div>

                  <p className="mt-1 text-xs text-charcoal/50">
                    From <span className="font-medium">{msg.visitor_name}</span> &lt;{msg.email}&gt;
                    · {new Date(msg.created_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
                  </p>

                  <p className="mt-2 text-sm text-charcoal/70">{msg.message}</p>

                  {msg.reply && (
                    <div className="mt-3 rounded-xl bg-sand-light p-3">
                      <p className="text-xs font-medium text-forest">Staff reply:</p>
                      <p className="mt-1 text-sm text-charcoal/70">{msg.reply}</p>
                    </div>
                  )}
                </div>

                {/* Actions */}
                <div className="flex flex-shrink-0 gap-1">
                  {msg.status === 'unread' && (
                    <button
                      onClick={() => markAs(msg.id, 'read')}
                      className="rounded-lg p-2 text-charcoal/40 hover:bg-sand/60 hover:text-forest transition-colors"
                      title="Mark as read"
                    >
                      <Eye className="h-4 w-4" />
                    </button>
                  )}
                  {msg.status !== 'replied' && (
                    <button
                      onClick={() => openReply(msg)}
                      className="rounded-lg p-2 text-charcoal/40 hover:bg-green-50 hover:text-green-700 transition-colors"
                      title="Reply"
                    >
                      <Reply className="h-4 w-4" />
                    </button>
                  )}
                  {msg.status !== 'archived' && (
                    <button
                      onClick={() => markAs(msg.id, 'archived')}
                      className="rounded-lg p-2 text-charcoal/40 hover:bg-sand/60 hover:text-charcoal transition-colors"
                      title="Archive"
                    >
                      <Archive className="h-4 w-4" />
                    </button>
                  )}
                  <button
                    onClick={() => setDeleting(msg)}
                    className="rounded-lg p-2 text-charcoal/40 hover:bg-red-50 hover:text-red-600 transition-colors"
                    title="Delete"
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
              </div>
            </motion.div>
          );
        })}

        {!loading && (!messages || messages.length === 0) && (
          <div className="py-12 text-center">
            <MessageSquare className="mx-auto h-10 w-10 text-charcoal/20" />
            <p className="mt-3 text-charcoal/40">No messages.</p>
          </div>
        )}
      </div>

      {/* Reply modal */}
      <Modal
        open={!!replying}
        onClose={() => { setReplying(null); setReplyText(''); }}
        title={`Reply — ${replying?.subject}`}
      >
        <div className="space-y-4">
          <div className="rounded-xl bg-sand-light p-3 text-sm">
            <p className="text-xs font-medium text-charcoal/50">
              From {replying?.visitor_name} &lt;{replying?.email}&gt;
            </p>
            <p className="mt-1 text-charcoal/70">{replying?.message}</p>
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium text-charcoal/60">Your reply</label>
            <textarea
              value={replyText}
              onChange={(e) => setReplyText(e.target.value)}
              rows={5}
              placeholder="Type your response…"
              className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20 resize-none"
            />
          </div>
          <div className="flex justify-end gap-3">
            <button
              onClick={() => { setReplying(null); setReplyText(''); }}
              className="btn-secondary text-sm"
            >
              Cancel
            </button>
            <button
              onClick={sendReply}
              disabled={saving || !replyText.trim()}
              className="btn-primary text-sm disabled:opacity-50"
            >
              <Send className="h-4 w-4" />
              {saving ? 'Sending…' : 'Send Reply'}
            </button>
          </div>
        </div>
      </Modal>

      <ConfirmDialog
        open={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={handleDelete}
        title="Delete Message"
        message={`Delete "${deleting?.subject}" from ${deleting?.visitor_name}? This cannot be undone.`}
        loading={saving}
      />
    </div>
  );
}
