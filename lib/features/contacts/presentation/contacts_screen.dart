import 'package:flutter/material.dart';

import '../domain/contact.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    required this.contacts,
    required this.onContactTap,
    this.unreadCounts = const <String, int>{},
    this.selectedContactId,
    this.embedded = false,
  });

  final List<Contact> contacts;
  final void Function(Contact contact) onContactTap;
  final Map<String, int> unreadCounts;
  final String? selectedContactId;
  final bool embedded;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = ListView.builder(
      key: const PageStorageKey('contacts-list'),
      itemCount: widget.contacts.length,
      padding:
          widget.embedded
              ? const EdgeInsets.fromLTRB(12, 8, 12, 16)
              : EdgeInsets.zero,
      itemBuilder: (context, index) {
        final contact = widget.contacts[index];
        final selected = contact.id == widget.selectedContactId;
        final unreadCount = widget.unreadCounts[contact.id] ?? 0;
        final tile = ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(widget.embedded ? 18 : 12),
          ),
          tileColor: selected ? const Color(0xFFF1EBFF) : null,
          selectedTileColor: const Color(0xFFF1EBFF),
          leading: CircleAvatar(
            backgroundImage:
                contact.avatarAssetPath != null
                    ? AssetImage(contact.avatarAssetPath!)
                    : null,
            child:
                contact.avatarAssetPath == null
                    ? Text(contact.name[0].toUpperCase())
                    : null,
          ),
          title: Text(
            contact.name,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          subtitle: Text(
            contact.subtitle ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing:
              widget.embedded
                  ? _UnreadBadge(
                    unreadCount: unreadCount,
                    selected: selected,
                    compact: true,
                  )
                  : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (unreadCount > 0) ...[
                        _UnreadBadge(
                          unreadCount: unreadCount,
                          selected: selected,
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Icon(Icons.chevron_right),
                    ],
                  ),
          onTap: () => widget.onContactTap(contact),
        );
        if (!widget.embedded) return tile;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: tile,
        );
      },
    );

    if (widget.embedded) {
      return Material(color: Colors.transparent, child: body);
    }

    return Scaffold(appBar: AppBar(title: const Text('通讯录')), body: body);
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({
    required this.unreadCount,
    required this.selected,
    this.compact = false,
  });

  final int unreadCount;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (unreadCount <= 0) {
      return Container(
        width: compact ? 10 : 8,
        height: compact ? 10 : 8,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF8B5CF6) : const Color(0xFFD6DAE6),
          shape: BoxShape.circle,
        ),
      );
    }
    final label = unreadCount > 99 ? '99+' : '$unreadCount';
    return Container(
      constraints: BoxConstraints(
        minWidth: compact ? 22 : 24,
        minHeight: compact ? 22 : 24,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 8,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x24EF4444),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}
