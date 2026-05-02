import 'package:flutter/material.dart';

import '../domain/contact.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    required this.contacts,
    required this.onContactTap,
    this.selectedContactId,
    this.embedded = false,
  });

  final List<Contact> contacts;
  final void Function(Contact contact) onContactTap;
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
                  ? Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color:
                          selected
                              ? const Color(0xFF8B5CF6)
                              : const Color(0xFFD6DAE6),
                      shape: BoxShape.circle,
                    ),
                  )
                  : const Icon(Icons.chevron_right),
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
