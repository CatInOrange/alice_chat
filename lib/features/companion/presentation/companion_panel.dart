import 'package:flutter/material.dart';

import '../../chat/application/chat_session_store.dart';
import '../../chat/domain/chat_session.dart';

class CompanionPanel extends StatelessWidget {
  const CompanionPanel({
    super.key,
    required this.session,
    required this.state,
    this.compact = false,
    this.live2dVisible = false,
    this.onOpenLive2d,
    this.onOpenMusic,
  });

  final ChatSession? session;
  final ChatViewState? state;
  final bool compact;
  final bool live2dVisible;
  final VoidCallback? onOpenLive2d;
  final VoidCallback? onOpenMusic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentSession = session;
    final currentState = state;
    final title = currentSession?.title ?? 'AliceChat';
    final subtitle = _buildSubtitle(currentSession, currentState);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        border: Border(
          left: BorderSide(
            color: const Color(0xFFE8EAF2),
            width: compact ? 0 : 1,
          ),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 18,
            18,
            compact ? 16 : 18,
            18,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CharacterCard(
                title: title,
                subtitle: subtitle,
                avatarAssetPath: currentSession?.avatarAssetPath,
                accent: _accentForSession(currentSession),
              ),
              const SizedBox(height: 18),
              Text(
                '快捷动作',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2D3443),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _QuickActionChip(
                    icon:
                        live2dVisible
                            ? Icons.auto_awesome
                            : Icons.auto_awesome_outlined,
                    label: live2dVisible ? '收起 Live2D' : '打开 Live2D',
                    onTap: onOpenLive2d,
                  ),
                  _QuickActionChip(
                    icon: Icons.library_music_outlined,
                    label: '音乐',
                    onTap: onOpenMusic,
                  ),
                  _QuickActionChip(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: '新话题',
                    onTap: null,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '会话状态',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2D3443),
                ),
              ),
              const SizedBox(height: 10),
              _InfoCard(
                children: [
                  _InfoRow(label: '连接', value: _connectionLabel(currentState)),
                  _InfoRow(label: '回复状态', value: _replyLabel(currentState)),
                  _InfoRow(
                    label: '消息数',
                    value: '${currentState?.messages.length ?? 0}',
                  ),
                  _InfoRow(
                    label: '会话ID',
                    value:
                        currentState?.backendSessionId?.isNotEmpty == true
                            ? currentState!.backendSessionId!
                            : (currentSession?.backendSessionId ??
                                currentSession?.id ??
                                '-'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                '陪伴提示',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2D3443),
                ),
              ),
              const SizedBox(height: 10),
              _InfoCard(
                children: [
                  Text(
                    _supportiveCopy(currentSession, currentState),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF5D6575),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
              if (!compact) const Spacer(),
              if (!compact)
                Text(
                  '85% 桌面效率 + 15% 陪伴氛围',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF98A1B3),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildSubtitle(ChatSession? session, ChatViewState? state) {
    if (session == null) return '轻陪伴工作台';
    if (state?.isAssistantStreaming == true) return '正在认真回复你';
    return session.subtitle.isNotEmpty ? session.subtitle : '在线陪你聊天';
  }

  String _connectionLabel(ChatViewState? state) {
    if (state == null) return '未连接';
    if (state.isEventConnecting) return '重连中';
    if ((state.backendSessionId ?? '').isNotEmpty) return '已连接';
    return '未连接';
  }

  String _replyLabel(ChatViewState? state) {
    if (state == null) return '空闲';
    if (state.isAssistantStreaming) return '回复中';
    if (state.isSubmitting) return '发送中';
    return '空闲';
  }

  String _supportiveCopy(ChatSession? session, ChatViewState? state) {
    if (state?.isAssistantStreaming == true) {
      return '${session?.title ?? '她'}正在整理回答，稍等一下下。';
    }
    if (session == null) {
      return '在桌面端把聊天、网页和音乐都放进一个安静的工作台里。';
    }
    return '${session.title}会一直待在这里，聊天是主角，陪伴感只做轻轻一层。';
  }

  Color _accentForSession(ChatSession? session) {
    switch (session?.id) {
      case 'yulinglong':
        return const Color(0xFF5BA7FF);
      case 'lisuxin':
        return const Color(0xFF59B38C);
      case 'alice':
      default:
        return const Color(0xFF8B5CF6);
    }
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({
    required this.title,
    required this.subtitle,
    required this.avatarAssetPath,
    required this.accent,
  });

  final String title;
  final String subtitle;
  final String? avatarAssetPath;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.14), Colors.white],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: accent.withValues(alpha: 0.12),
            backgroundImage:
                avatarAssetPath != null ? AssetImage(avatarAssetPath!) : null,
            child:
                avatarAssetPath == null
                    ? Text(title.isEmpty ? '?' : title.characters.first)
                    : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF2A3140),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF667085),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionChip extends StatelessWidget {
  const _QuickActionChip({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8EAF2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF6D4AFF)),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF40485A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8EAF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF98A1B3),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF40485A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
