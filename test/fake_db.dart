import 'package:toneup_read/services/db_service.dart';

/// 测试用：不触碰 sqflite 的空实现。
class FakeDb extends DbService {
  @override
  Future<List<Map<String, dynamic>>> select(String sql, [List<Object?>? params]) async => [];
  @override
  Future<void> execute(String sql, [List<Object?>? params]) async {}
  // 兜底：不覆写会落到 DbService 真开 sqflite（单测里必炸）。默认当作"新插入"。
  @override
  Future<int> insertReturnId(String sql, [List<Object?>? params]) async => 1;
  @override
  Future<void> clearCache() async {}
  @override
  Future<void> clearAll() async {}
}
