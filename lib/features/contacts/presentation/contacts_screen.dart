import 'package:flutter/material.dart';

import '../domain/contact.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    required this.contacts,
    required this.onContactTap,
  });

  final List<Contact> contacts;
  final void Function(Contact contact) onContactTap;

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
    return Scaffold(
      appBar: AppBar(title: const Text('通讯录')),
      body: ListView.builder(
        key: const PageStorageKey('contacts-list'),
        itemCount: widget.contacts.length,
        itemBuilder: (context, index) {
          final contact = widget.contacts[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundImage: contact.avatarAssetPath != null
                  ? AssetImage(contact.avatarAssetPath!)
                  : null,
              child: contact.avatarAssetPath == null
                  ? Text(contact.name[0].toUpperCase())
                  : null,
            ),
            title: Text(contact.name),
            subtitle: Text(contact.subtitle ?? ''),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => widget.onContactTap(contact),
          );
        },
      ),
    );
  }
}
