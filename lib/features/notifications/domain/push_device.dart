class PushDeviceRegistration {
  const PushDeviceRegistration({
    required this.deviceId,
    required this.pushToken,
    this.userId = 'alicechat-user',
    this.platform = 'android',
    this.provider = 'fcm',
    this.appVersion = '',
    this.deviceName = '',
    this.notificationEnabled = true,
  });

  final String userId;
  final String deviceId;
  final String platform;
  final String provider;
  final String pushToken;
  final String appVersion;
  final String deviceName;
  final bool notificationEnabled;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'deviceId': deviceId,
    'platform': platform,
    'provider': provider,
    'pushToken': pushToken,
    'appVersion': appVersion,
    'deviceName': deviceName,
    'notificationEnabled': notificationEnabled,
  };
}

class PushPresenceUpdate {
  const PushPresenceUpdate({
    required this.deviceId,
    required this.isForeground,
    this.activeSessionId = '',
  });

  final String deviceId;
  final bool isForeground;
  final String activeSessionId;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'isForeground': isForeground,
    'activeSessionId': activeSessionId,
  };
}
