import '../contracts/collections.dart';
import '../data/db.dart';
import '../data/query.dart';
import '../data/record.dart';
import '../data/record_store.dart';

/// In-app notifications (the bell). One record per recipient.
class NotificationService {
  NotificationService(this.store);
  final RecordStore store;

  /// Active users who hold [permission] through any of their roles.
  Future<List<Rec>> usersWith(String permission) async {
    final roles = await store.query(const Query(Col.roles));
    final granted = {
      for (final r in roles)
        if (r.list<String>('permissions').any((p) => p == '*' || p == permission)) r.id,
    };
    final users = await store.query(const Query(Col.users).eq('active', true));
    return users.where((u) => u.list<String>('role_ids').any(granted.contains)).toList();
  }

  Future<void> notifyPermission(
    Db db, {
    required String permission,
    required String title,
    String body = '',
    String severity = 'info',
    String kind = 'system',
    String? routeId,
    Map<String, Object?> routeArgs = const {},
    String? exceptUserId,
  }) async {
    final users = await usersWith(permission);
    await db.batch([
      for (final u in users)
        if (u.id != exceptUserId)
          InsertOp(Col.notifications, {
            'user_id': u.id,
            'title': title,
            'body': body,
            'severity': severity,
            'kind': kind,
            'route_id': routeId,
            'route_args': routeArgs,
            'read': false,
          }),
    ]);
  }

  Future<void> notifyUser(
    Db db,
    String userId, {
    required String title,
    String body = '',
    String severity = 'info',
    String kind = 'system',
    String? routeId,
    Map<String, Object?> routeArgs = const {},
  }) =>
      db.insert(Col.notifications, {
        'user_id': userId,
        'title': title,
        'body': body,
        'severity': severity,
        'kind': kind,
        'route_id': routeId,
        'route_args': routeArgs,
        'read': false,
      });

  Query unreadFor(String userId) =>
      const Query(Col.notifications).eq('user_id', userId).eq('read', false).take(50);

  Future<void> markAllRead(Db db, String userId) async {
    final unread = await store.query(const Query(Col.notifications).eq('user_id', userId).eq('read', false));
    await db.batch([for (final n in unread) UpdateOp(Col.notifications, n.id, {'read': true})]);
  }
}
