import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'android_chat_store.dart';

class AndroidDbStore {
  AndroidDbStore._();

  static final AndroidDbStore instance = AndroidDbStore._();

  Database? _db;
  Future<Database>? _opening;

  bool get isOpen => _db != null;

  Future<void> init(String password) async {
    if (_db != null) return;
    final opening = _opening;
    if (opening != null) {
      final db = await opening;
      if (_db == null && identical(_opening, opening)) {
        _db = db;
      }
      return;
    }

    final nextOpening = _open(password);
    _opening = nextOpening;
    try {
      final db = await nextOpening;
      if (identical(_opening, nextOpening)) {
        _db = db;
      }
    } finally {
      if (identical(_opening, nextOpening)) {
        _opening = null;
      }
    }
  }

  Future<Database> _open(String password) async {
    final dbDir = await getDatabasesPath();
    final dbPath = join(dbDir, 'envelope_chat_secure.db');

    return openDatabase(
      dbPath,
      password: password,
      version: 10,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            key_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            contact_json TEXT NOT NULL,
            remark TEXT,
            device_id TEXT,
            p2p_ticket TEXT,
            p2p_ticket_updated_at_unix_ms INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE messages (
            envelope_id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            peer_key_id TEXT NOT NULL,
            peer_display_name TEXT NOT NULL,
            created_at_unix_ms INTEGER NOT NULL,
            message_counter INTEGER NOT NULL,
            text TEXT NOT NULL,
            opaque_envelope_b64 TEXT NOT NULL,
            delivery_status TEXT NOT NULL,
            delivery_detail TEXT,
            delivery_updated_at_unix_ms INTEGER,
            attachment_uri TEXT,
            attachment_path TEXT,
            attachment_mime TEXT,
            attachment_deleted_at_unix_ms INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
        await _createFileTransferTables(db);
        await _createSealedEnvelopeTable(db);
        await _createGroupTables(db);
        await _createReceivedMessageCounterTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE contacts ADD COLUMN remark TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE messages_new (
              envelope_id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              direction TEXT NOT NULL,
              peer_key_id TEXT NOT NULL,
              peer_display_name TEXT NOT NULL,
              created_at_unix_ms INTEGER NOT NULL,
              message_counter INTEGER NOT NULL,
              text TEXT NOT NULL,
              opaque_envelope_b64 TEXT NOT NULL,
              delivery_status TEXT NOT NULL,
              delivery_detail TEXT,
              delivery_updated_at_unix_ms INTEGER
            )
          ''');
          await db.execute('''
            INSERT INTO messages_new (
              envelope_id,
              conversation_id,
              direction,
              peer_key_id,
              peer_display_name,
              created_at_unix_ms,
              message_counter,
              text,
              opaque_envelope_b64,
              delivery_status,
              delivery_detail,
              delivery_updated_at_unix_ms
            )
            SELECT
              envelope_id,
              conversation_id,
              direction,
              peer_key_id,
              peer_display_name,
              created_at_unix_ms,
              message_counter,
              text,
              '',
              delivery_status,
              delivery_detail,
              delivery_updated_at_unix_ms
            FROM messages
          ''');
          await db.execute('DROP TABLE messages');
          await db.execute('ALTER TABLE messages_new RENAME TO messages');
        }
        if (oldVersion < 4) {
          await _createFileTransferTables(db);
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN attachment_uri TEXT',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN attachment_path TEXT',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN attachment_mime TEXT',
          );
        }
        if (oldVersion < 6) {
          await _createSealedEnvelopeTable(db);
        }
        if (oldVersion < 7) {
          await _createGroupTables(db);
        }
        if (oldVersion < 8) {
          await _addSealedEnvelopeFileColumns(db);
        }
        if (oldVersion < 9) {
          await _addCachedFileDeletedColumns(db);
        }
        if (oldVersion < 10) {
          await _createReceivedMessageCounterTable(db);
          await _backfillReceivedMessageCounters(db);
        }
      },
    );
  }

  Future<void> _addColumnIfMissing(
    DatabaseExecutor db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name']?.toString() == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $definition');
    }
  }

  Future<void> _createFileTransferTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_transfers (
        transfer_id TEXT PRIMARY KEY,
        message_envelope_id TEXT,
        direction TEXT NOT NULL,
        peer_key_id TEXT NOT NULL,
        peer_display_name TEXT NOT NULL,
        created_at_unix_ms INTEGER NOT NULL,
        message_counter INTEGER NOT NULL,
        filename TEXT NOT NULL,
        mime TEXT NOT NULL,
        total_size INTEGER NOT NULL,
        chunk_size INTEGER NOT NULL,
        chunk_count INTEGER NOT NULL,
        file_sha256 TEXT NOT NULL,
        manifest_envelope_id TEXT,
        manifest_envelope_b64 TEXT,
        manifest_json TEXT,
        status TEXT NOT NULL,
        saved_path TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_file_transfers_message_envelope
      ON file_transfers(message_envelope_id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_transfer_chunks (
        transfer_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk_sha256 TEXT NOT NULL,
        chunk_size INTEGER NOT NULL,
        envelope_id TEXT,
        envelope_b64 TEXT,
        chunk_data_b64 TEXT,
        PRIMARY KEY (transfer_id, chunk_index)
      )
    ''');
  }

  Future<void> _createSealedEnvelopeTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sealed_envelopes (
        envelope_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        recipient_key_id TEXT NOT NULL,
        recipient_display_name TEXT NOT NULL,
        created_at_unix_ms INTEGER NOT NULL,
        message_counter INTEGER NOT NULL,
        source_name TEXT,
        payload_size INTEGER NOT NULL,
        envelope_size INTEGER NOT NULL,
        path TEXT NOT NULL,
        uri TEXT,
        display_path TEXT,
        mime TEXT,
        size_bytes INTEGER,
        deleted_at_unix_ms INTEGER
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sealed_envelopes_created_at
      ON sealed_envelopes(created_at_unix_ms DESC)
    ''');
  }

  Future<void> _addSealedEnvelopeFileColumns(DatabaseExecutor db) async {
    await _addColumnIfMissing(db, 'sealed_envelopes', 'uri', 'uri TEXT');
    await _addColumnIfMissing(
      db,
      'sealed_envelopes',
      'display_path',
      'display_path TEXT',
    );
    await _addColumnIfMissing(db, 'sealed_envelopes', 'mime', 'mime TEXT');
    await _addColumnIfMissing(
      db,
      'sealed_envelopes',
      'size_bytes',
      'size_bytes INTEGER',
    );
  }

  Future<void> _addCachedFileDeletedColumns(DatabaseExecutor db) async {
    await _addColumnIfMissing(
      db,
      'messages',
      'attachment_deleted_at_unix_ms',
      'attachment_deleted_at_unix_ms INTEGER',
    );
    await _addColumnIfMissing(
      db,
      'sealed_envelopes',
      'deleted_at_unix_ms',
      'deleted_at_unix_ms INTEGER',
    );
  }

  Future<void> _createGroupTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner_key_id TEXT NOT NULL,
        policy TEXT NOT NULL,
        epoch INTEGER NOT NULL,
        created_at_unix_ms INTEGER NOT NULL,
        updated_at_unix_ms INTEGER NOT NULL,
        avatar_seed TEXT,
        is_active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_groups_updated_at
      ON groups(updated_at_unix_ms DESC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_members (
        group_id TEXT NOT NULL,
        key_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        contact_json TEXT NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL,
        trust_state TEXT NOT NULL,
        invited_by_key_id TEXT,
        joined_at_unix_ms INTEGER,
        updated_at_unix_ms INTEGER NOT NULL,
        PRIMARY KEY (group_id, key_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_group_members_status
      ON group_members(group_id, status)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_events (
        event_id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        epoch INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        actor_key_id TEXT NOT NULL,
        created_at_unix_ms INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        signature TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_group_events_group_created
      ON group_events(group_id, created_at_unix_ms ASC)
    ''');
  }

  Future<void> _createReceivedMessageCounterTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS received_message_counters (
        sender_key_id TEXT NOT NULL,
        message_counter INTEGER NOT NULL,
        conversation_id TEXT NOT NULL,
        envelope_id TEXT NOT NULL,
        first_seen_at_unix_ms INTEGER NOT NULL,
        PRIMARY KEY (sender_key_id, message_counter)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_received_message_counters_envelope
      ON received_message_counters(envelope_id)
    ''');
  }

  Future<void> _backfillReceivedMessageCounters(DatabaseExecutor db) async {
    await db.execute('''
      INSERT OR IGNORE INTO received_message_counters (
        sender_key_id,
        message_counter,
        conversation_id,
        envelope_id,
        first_seen_at_unix_ms
      )
      SELECT
        peer_key_id,
        message_counter,
        conversation_id,
        envelope_id,
        created_at_unix_ms
      FROM messages
      WHERE direction = 'incoming'
        AND peer_key_id <> ''
        AND conversation_id <> ''
        AND message_counter > 0
    ''');
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    final db = _db;
    _db = null;
    if (opening != null) {
      final opened = await opening;
      if (!identical(opened, db)) {
        await opened.close();
      }
    }
    await db?.close();
  }

  Database _getDb() {
    final db = _db;
    if (db == null) {
      throw StateError('Database has not been initialized. Call init() first.');
    }
    return db;
  }

  // --- Contacts ---

  Future<List<AndroidContactRecord>> getContacts() async {
    final db = _getDb();
    final maps = await db.query(
      'contacts',
      orderBy:
          "CASE WHEN remark IS NULL OR remark = '' THEN display_name ELSE remark END ASC",
    );
    return maps.map((map) => AndroidContactRecord.fromJson(map)).toList();
  }

  Future<AndroidContactRecord?> getContact(String keyId) async {
    final db = _getDb();
    final maps = await db.query(
      'contacts',
      where: 'key_id = ?',
      whereArgs: [keyId],
    );
    if (maps.isEmpty) return null;
    return AndroidContactRecord.fromJson(maps.first);
  }

  Future<void> upsertContact(AndroidContactRecord contact) async {
    final db = _getDb();
    final existing = await getContact(contact.keyId);
    final next = existing != null && !contact.hasRemark && existing.hasRemark
        ? contact.copyWith(remark: existing.remark)
        : contact;
    await db.insert(
      'contacts',
      next.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateContactRemark({
    required String keyId,
    required String remark,
  }) async {
    final db = _getDb();
    await db.update(
      'contacts',
      {'remark': remark.trim().isEmpty ? null : remark.trim()},
      where: 'key_id = ?',
      whereArgs: [keyId],
    );
  }

  Future<int> deleteContact(String keyId) async {
    final db = _getDb();
    final normalizedKeyId = keyId.trim();
    if (normalizedKeyId.isEmpty) return 0;
    return db.delete(
      'contacts',
      where: 'key_id = ?',
      whereArgs: [normalizedKeyId],
    );
  }

  // --- Messages ---

  Future<List<AndroidMessageRecord>> getMessages({
    String? peerKeyId,
    String? conversationId,
    bool excludeGroupConversations = false,
    int? limit,
    int? offset,
  }) async {
    final db = _getDb();
    final normalizedPeerKeyId = peerKeyId?.trim() ?? '';
    final normalizedConversationId = conversationId?.trim() ?? '';
    final clauses = <String>[];
    final args = <Object?>[];
    if (normalizedPeerKeyId.isNotEmpty) {
      clauses.add('peer_key_id = ?');
      args.add(normalizedPeerKeyId);
    }
    if (normalizedConversationId.isNotEmpty) {
      clauses.add('conversation_id = ?');
      args.add(normalizedConversationId);
    }
    if (excludeGroupConversations) {
      clauses.add('conversation_id NOT IN (SELECT group_id FROM groups)');
    }
    final maps = await db.query(
      'messages',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at_unix_ms DESC',
      limit: limit,
      offset: offset,
    );
    // Note: main.dart expects messages sorted chronologically (ascending).
    // The UI reverses the list for rendering, but to keep existing ordering logic
    // we reverse the sorted list from DESC query to return it ASC.
    final list = maps.map((map) => AndroidMessageRecord.fromJson(map)).toList();
    return list.reversed.toList();
  }

  Future<int> getMessageCount({
    String? peerKeyId,
    String? conversationId,
    bool excludeGroupConversations = false,
  }) {
    final normalizedPeerKeyId = peerKeyId?.trim() ?? '';
    final normalizedConversationId = conversationId?.trim() ?? '';
    final clauses = <String>[];
    final args = <Object?>[];
    if (normalizedPeerKeyId.isNotEmpty) {
      clauses.add('peer_key_id = ?');
      args.add(normalizedPeerKeyId);
    }
    if (normalizedConversationId.isNotEmpty) {
      clauses.add('conversation_id = ?');
      args.add(normalizedConversationId);
    }
    if (excludeGroupConversations) {
      clauses.add('conversation_id NOT IN (SELECT group_id FROM groups)');
    }
    return _countMessages(
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
    );
  }

  Future<Map<String, int>> getIncomingMessageCountsByPeer() async {
    final db = _getDb();
    final maps = await db.rawQuery(
      '''
      SELECT peer_key_id, COUNT(*) AS count
      FROM messages
      WHERE direction = ?
        AND conversation_id NOT IN (SELECT group_id FROM groups)
      GROUP BY peer_key_id
    ''',
      ['incoming'],
    );
    return {
      for (final map in maps)
        if ((map['peer_key_id']?.toString() ?? '').isNotEmpty)
          map['peer_key_id'].toString(): map['count'] is int
              ? map['count'] as int
              : int.tryParse(map['count']?.toString() ?? '') ?? 0,
    };
  }

  Future<Map<String, int>> getIncomingMessageCountsByConversation() async {
    final db = _getDb();
    final maps = await db.rawQuery(
      '''
      SELECT conversation_id, COUNT(*) AS count
      FROM messages
      WHERE direction = ?
      GROUP BY conversation_id
    ''',
      ['incoming'],
    );
    return {
      for (final map in maps)
        if ((map['conversation_id']?.toString() ?? '').isNotEmpty)
          map['conversation_id'].toString(): map['count'] is int
              ? map['count'] as int
              : int.tryParse(map['count']?.toString() ?? '') ?? 0,
    };
  }

  Future<AndroidMessageRecord?> getMessage(String envelopeId) async {
    final db = _getDb();
    final maps = await db.query(
      'messages',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AndroidMessageRecord.fromJson(maps.first);
  }

  Future<List<AndroidMessageRecord>> getPendingMessages() async {
    final db = _getDb();
    final maps = await db.query(
      'messages',
      where: 'direction = ? AND delivery_status = ?',
      whereArgs: ['outgoing', AndroidDeliveryStatus.pending],
      orderBy: 'created_at_unix_ms ASC',
    );
    return maps.map((map) => AndroidMessageRecord.fromJson(map)).toList();
  }

  Future<int> getPendingMessageCount() => _countMessages(
    where: 'direction = ? AND delivery_status = ?',
    whereArgs: ['outgoing', AndroidDeliveryStatus.pending],
  );

  Future<List<AndroidMessageRecord>> getServerMailboxMessages({
    int limit = 100,
  }) async {
    final db = _getDb();
    final maps = await db.query(
      'messages',
      where: 'direction = ? AND delivery_status = ?',
      whereArgs: ['outgoing', AndroidDeliveryStatus.serverMailbox],
      orderBy: 'created_at_unix_ms ASC',
      limit: limit,
    );
    return maps.map((map) => AndroidMessageRecord.fromJson(map)).toList();
  }

  Future<AndroidMessageRecord?> getLatestOutgoingMessage() async {
    final db = _getDb();
    final maps = await db.query(
      'messages',
      where: 'direction = ?',
      whereArgs: ['outgoing'],
      orderBy: 'created_at_unix_ms DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AndroidMessageRecord.fromJson(maps.first);
  }

  Future<bool> addMessage(AndroidMessageRecord message) async {
    final db = _getDb();
    return db.transaction((txn) async {
      final existing = await txn.query(
        'messages',
        columns: ['envelope_id'],
        where: 'envelope_id = ?',
        whereArgs: [message.envelopeId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return false;
      }
      if (message.direction == 'incoming') {
        final counterInserted = await _recordReceivedMessageCounter(
          txn,
          message,
        );
        if (!counterInserted) {
          return false;
        }
      }
      final rowId = await txn.insert(
        'messages',
        message.toJson(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return rowId != 0;
    });
  }

  Future<bool> _recordReceivedMessageCounter(
    DatabaseExecutor db,
    AndroidMessageRecord message,
  ) async {
    final senderKeyId = message.peerKeyId.trim();
    final conversationId = message.conversationId.trim();
    if (!message.hasTrackableIncomingCounter) {
      return false;
    }
    final rowId = await db.insert('received_message_counters', {
      'sender_key_id': senderKeyId,
      'message_counter': message.messageCounter,
      'conversation_id': conversationId,
      'envelope_id': message.envelopeId,
      'first_seen_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return rowId != 0;
  }

  Future<void> upsertMessage(AndroidMessageRecord message) async {
    final db = _getDb();
    await db.insert(
      'messages',
      message.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateMessageDelivery({
    required String envelopeId,
    required String deliveryStatus,
    String? deliveryDetail,
  }) async {
    final db = _getDb();
    await db.update(
      'messages',
      {
        'delivery_status': deliveryStatus,
        'delivery_detail': deliveryDetail,
        'delivery_updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
    );
  }

  Future<int> deleteMessages(List<String> envelopeIds) async {
    final normalizedIds = envelopeIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedIds.isEmpty) return 0;

    final db = _getDb();
    final placeholders = List.filled(normalizedIds.length, '?').join(',');
    return db.transaction((txn) async {
      final transfers = await txn.query(
        'file_transfers',
        columns: ['transfer_id'],
        where:
            'message_envelope_id IN ($placeholders) OR manifest_envelope_id IN ($placeholders)',
        whereArgs: [...normalizedIds, ...normalizedIds],
      );
      final transferIds = transfers
          .map((map) => map['transfer_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (transferIds.isNotEmpty) {
        final transferPlaceholders = List.filled(
          transferIds.length,
          '?',
        ).join(',');
        await txn.delete(
          'file_transfer_chunks',
          where: 'transfer_id IN ($transferPlaceholders)',
          whereArgs: transferIds,
        );
        await txn.delete(
          'file_transfers',
          where: 'transfer_id IN ($transferPlaceholders)',
          whereArgs: transferIds,
        );
      }
      return txn.delete(
        'messages',
        where: 'envelope_id IN ($placeholders)',
        whereArgs: normalizedIds,
      );
    });
  }

  Future<int> markCachedMessageFilesDeleted({
    required int deletedAtUnixMs,
  }) async {
    final db = _getDb();
    return db.update(
      'messages',
      {'attachment_deleted_at_unix_ms': deletedAtUnixMs},
      where:
          "((attachment_path LIKE '%Download/Envelope/received/%') OR "
          "(attachment_path LIKE '%Downloads/Envelope/received/%') OR "
          "text LIKE '%Download/Envelope/received/%' OR "
          "text LIKE '%Downloads/Envelope/received/%') AND "
          "(attachment_deleted_at_unix_ms IS NULL OR "
          'attachment_deleted_at_unix_ms <= 0)',
    );
  }

  // --- Chunked File Transfers ---

  Future<void> saveOutgoingFileTransfer({
    required String transferId,
    required String messageEnvelopeId,
    required String peerKeyId,
    required String peerDisplayName,
    required int createdAtUnixMs,
    required int messageCounter,
    required String filename,
    required String mime,
    required int totalSize,
    required int chunkSize,
    required int chunkCount,
    required String fileSha256,
    required String manifestEnvelopeId,
    required String manifestEnvelopeBase64,
    required String manifestJson,
    required List<Map<String, Object?>> chunks,
  }) async {
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.insert('file_transfers', {
        'transfer_id': transferId,
        'message_envelope_id': messageEnvelopeId,
        'direction': 'outgoing',
        'peer_key_id': peerKeyId,
        'peer_display_name': peerDisplayName,
        'created_at_unix_ms': createdAtUnixMs,
        'message_counter': messageCounter,
        'filename': filename,
        'mime': mime,
        'total_size': totalSize,
        'chunk_size': chunkSize,
        'chunk_count': chunkCount,
        'file_sha256': fileSha256,
        'manifest_envelope_id': manifestEnvelopeId,
        'manifest_envelope_b64': manifestEnvelopeBase64,
        'manifest_json': manifestJson,
        'status': AndroidDeliveryStatus.created,
        'saved_path': null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final chunk in chunks) {
        await txn.insert('file_transfer_chunks', {
          'transfer_id': transferId,
          'chunk_index': chunk['chunk_index'],
          'chunk_sha256': chunk['chunk_sha256'],
          'chunk_size': chunk['chunk_size'],
          'envelope_id': chunk['envelope_id'],
          'envelope_b64': chunk['envelope_b64'],
          'chunk_data_b64': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> saveOutgoingFileTransferChunk({
    required String transferId,
    required int chunkIndex,
    required String chunkSha256,
    required int chunkSize,
    required String envelopeId,
    required String envelopeBase64,
  }) async {
    final db = _getDb();
    await db.insert('file_transfer_chunks', {
      'transfer_id': transferId,
      'chunk_index': chunkIndex,
      'chunk_sha256': chunkSha256,
      'chunk_size': chunkSize,
      'envelope_id': envelopeId,
      'envelope_b64': envelopeBase64,
      'chunk_data_b64': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> getFileTransferByMessageEnvelopeId(
    String messageEnvelopeId,
  ) async {
    final db = _getDb();
    final maps = await db.query(
      'file_transfers',
      where: 'message_envelope_id = ?',
      whereArgs: [messageEnvelopeId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  Future<Map<String, Object?>?> getFileTransfer(String transferId) async {
    final db = _getDb();
    final maps = await db.query(
      'file_transfers',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  Future<List<Map<String, Object?>>> getFileTransferChunks(
    String transferId,
  ) async {
    final db = _getDb();
    return db.query(
      'file_transfer_chunks',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
      orderBy: 'chunk_index ASC',
    );
  }

  Future<void> upsertInboundFileManifest({
    required String transferId,
    required String messageEnvelopeId,
    required String peerKeyId,
    required String peerDisplayName,
    required int createdAtUnixMs,
    required int messageCounter,
    required String filename,
    required String mime,
    required int totalSize,
    required int chunkSize,
    required int chunkCount,
    required String fileSha256,
    required String manifestEnvelopeId,
    required String manifestEnvelopeBase64,
    required String manifestJson,
  }) async {
    final db = _getDb();
    await db.insert('file_transfers', {
      'transfer_id': transferId,
      'message_envelope_id': messageEnvelopeId,
      'direction': 'incoming',
      'peer_key_id': peerKeyId,
      'peer_display_name': peerDisplayName,
      'created_at_unix_ms': createdAtUnixMs,
      'message_counter': messageCounter,
      'filename': filename,
      'mime': mime,
      'total_size': totalSize,
      'chunk_size': chunkSize,
      'chunk_count': chunkCount,
      'file_sha256': fileSha256,
      'manifest_envelope_id': manifestEnvelopeId,
      'manifest_envelope_b64': manifestEnvelopeBase64,
      'manifest_json': manifestJson,
      'status': 'receiving',
      'saved_path': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertInboundFileChunk({
    required String transferId,
    required int chunkIndex,
    required String chunkSha256,
    required int chunkSize,
    required String envelopeId,
    required String chunkDataBase64,
  }) async {
    final db = _getDb();
    await db.insert('file_transfer_chunks', {
      'transfer_id': transferId,
      'chunk_index': chunkIndex,
      'chunk_sha256': chunkSha256,
      'chunk_size': chunkSize,
      'envelope_id': envelopeId,
      'envelope_b64': null,
      'chunk_data_b64': chunkDataBase64,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> getReceivedFileChunkCount(String transferId) async {
    final db = _getDb();
    final maps = await db.query(
      'file_transfer_chunks',
      columns: ['COUNT(*) AS count'],
      where: 'transfer_id = ? AND chunk_data_b64 IS NOT NULL',
      whereArgs: [transferId],
    );
    final value = maps.first['count'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> updateFileTransferStatus({
    required String transferId,
    required String status,
    String? savedPath,
  }) async {
    final db = _getDb();
    await db.update(
      'file_transfers',
      {'status': status, 'saved_path': savedPath},
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  // --- Groups ---

  Future<List<AndroidGroupRecord>> getGroups() async {
    final db = _getDb();
    final maps = await db.query(
      'groups',
      orderBy:
          "is_active DESC, CASE WHEN name IS NULL OR name = '' THEN group_id ELSE name END ASC",
    );
    return maps.map((map) => AndroidGroupRecord.fromJson(map)).toList();
  }

  Future<AndroidGroupRecord?> getGroup(String groupId) async {
    final db = _getDb();
    final maps = await db.query(
      'groups',
      where: 'group_id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AndroidGroupRecord.fromJson(maps.first);
  }

  Future<void> upsertGroup(AndroidGroupRecord group) async {
    final db = _getDb();
    await db.insert(
      'groups',
      group.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AndroidGroupMemberRecord>> getGroupMembers({
    String? groupId,
  }) async {
    final db = _getDb();
    final normalizedGroupId = groupId?.trim() ?? '';
    final maps = await db.query(
      'group_members',
      where: normalizedGroupId.isEmpty ? null : 'group_id = ?',
      whereArgs: normalizedGroupId.isEmpty ? null : [normalizedGroupId],
      orderBy:
          "group_id ASC, CASE role WHEN 'owner' THEN 0 ELSE 1 END ASC, display_name ASC",
    );
    return maps.map((map) => AndroidGroupMemberRecord.fromJson(map)).toList();
  }

  Future<AndroidGroupMemberRecord?> getGroupMember({
    required String groupId,
    required String keyId,
  }) async {
    final db = _getDb();
    final maps = await db.query(
      'group_members',
      where: 'group_id = ? AND key_id = ?',
      whereArgs: [groupId, keyId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AndroidGroupMemberRecord.fromJson(maps.first);
  }

  Future<void> upsertGroupMember(AndroidGroupMemberRecord member) async {
    final db = _getDb();
    await db.insert(
      'group_members',
      member.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertGroupMembers(
    Iterable<AndroidGroupMemberRecord> members,
  ) async {
    final db = _getDb();
    await db.transaction((txn) async {
      for (final member in members) {
        await txn.insert(
          'group_members',
          member.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> addGroupEvent(AndroidGroupEventRecord event) async {
    final db = _getDb();
    await db.insert(
      'group_events',
      event.toJson(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<AndroidGroupEventRecord>> getGroupEvents({
    required String groupId,
  }) async {
    final db = _getDb();
    final maps = await db.query(
      'group_events',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'created_at_unix_ms ASC',
    );
    return maps.map(AndroidGroupEventRecord.fromJson).toList();
  }

  Future<void> createGroupWithMembers({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required AndroidGroupEventRecord event,
  }) async {
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.insert(
        'groups',
        group.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final member in members) {
        await txn.insert(
          'group_members',
          member.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert(
        'group_events',
        event.toJson(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  Future<void> updateGroupMemberState({
    required String groupId,
    required String keyId,
    required String status,
    required String trustState,
    int? joinedAtUnixMs,
  }) async {
    final db = _getDb();
    await db.update(
      'group_members',
      {
        'status': AndroidGroupMemberStatus.normalize(status),
        'trust_state': AndroidGroupTrustState.normalize(trustState),
        'joined_at_unix_ms': joinedAtUnixMs,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'group_id = ? AND key_id = ?',
      whereArgs: [groupId, keyId],
    );
  }

  Future<void> updateGroupName({
    required String groupId,
    required String name,
  }) async {
    final db = _getDb();
    await db.update(
      'groups',
      {
        'name': name,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> deactivateGroup(String groupId) async {
    final db = _getDb();
    await db.update(
      'groups',
      {
        'is_active': 0,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
  }

  // --- Sealed Envelopes ---

  Future<void> addSealedEnvelope(AndroidSealedEnvelopeRecord record) async {
    final db = _getDb();
    await db.insert(
      'sealed_envelopes',
      record.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AndroidSealedEnvelopeRecord>> getSealedEnvelopes({
    int limit = 100,
  }) async {
    final db = _getDb();
    final maps = await db.query(
      'sealed_envelopes',
      orderBy: 'created_at_unix_ms DESC',
      limit: limit,
    );
    return maps.map(AndroidSealedEnvelopeRecord.fromJson).toList();
  }

  Future<int> markSealedEnvelopeFilesDeleted({
    required int deletedAtUnixMs,
  }) async {
    final db = _getDb();
    return db.update(
      'sealed_envelopes',
      {'deleted_at_unix_ms': deletedAtUnixMs},
      where:
          "((uri IS NOT NULL AND uri != '') OR "
          "(display_path IS NOT NULL AND display_path != '') OR "
          "path != '') AND "
          "(deleted_at_unix_ms IS NULL OR deleted_at_unix_ms <= 0)",
    );
  }

  Future<void> clearInboundFileChunkData(String transferId) async {
    final db = _getDb();
    await db.update(
      'file_transfer_chunks',
      {'chunk_data_b64': null},
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  Future<int> _countMessages({String? where, List<Object?>? whereArgs}) async {
    final db = _getDb();
    final maps = await db.query(
      'messages',
      columns: ['COUNT(*) AS count'],
      where: where,
      whereArgs: whereArgs,
    );
    final value = maps.first['count'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  // --- Metadata (Settings / Counters) ---

  Future<int> getNextMessageCounter() async {
    final db = _getDb();
    final maps = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['next_message_counter'],
    );
    if (maps.isEmpty) return 1;
    final valueStr = maps.first['value']?.toString();
    return int.tryParse(valueStr ?? '1') ?? 1;
  }

  Future<void> setNextMessageCounter(int counter) async {
    final db = _getDb();
    await db.insert('metadata', {
      'key': 'next_message_counter',
      'value': counter.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<AndroidChatStore> exportLocalBackupStore({
    bool includeMessages = false,
  }) async {
    return AndroidChatStore(
      contacts: await getContacts(),
      messages: includeMessages ? await getMessages() : const [],
      groups: await getGroups(),
      groupMembers: await getGroupMembers(),
      nextMessageCounter: await getNextMessageCounter(),
    ).normalized();
  }

  Future<void> importLocalBackupStore(AndroidChatStore store) async {
    final db = _getDb();
    final normalized = store.normalized();
    await db.transaction((txn) async {
      await txn.delete('contacts');
      await txn.delete('messages');
      await txn.delete('file_transfer_chunks');
      await txn.delete('file_transfers');
      await txn.delete('sealed_envelopes');
      await txn.delete('group_events');
      await txn.delete('group_members');
      await txn.delete('groups');
      await txn.delete('metadata');
      for (final contact in normalized.contacts) {
        await txn.insert(
          'contacts',
          contact.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final group in normalized.groups) {
        await txn.insert(
          'groups',
          group.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final member in normalized.groupMembers) {
        await txn.insert(
          'group_members',
          member.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final message in normalized.messages) {
        await txn.insert(
          'messages',
          message.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert('metadata', {
        'key': 'next_message_counter',
        'value': normalized.nextMessageCounter.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // --- Clean Store ---

  Future<void> clearAll() async {
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.delete('contacts');
      await txn.delete('messages');
      await txn.delete('file_transfer_chunks');
      await txn.delete('file_transfers');
      await txn.delete('sealed_envelopes');
      await txn.delete('group_events');
      await txn.delete('group_members');
      await txn.delete('groups');
      await txn.delete('metadata');
    });
  }

  // --- Migration ---

  Future<void> migrateFromOldStore(String oldStoreJson) async {
    if (oldStoreJson.trim().isEmpty) return;
    try {
      final oldStore = AndroidChatStore.fromJsonString(oldStoreJson);
      final db = _getDb();
      await db.transaction((txn) async {
        for (final contact in oldStore.contacts) {
          await txn.insert(
            'contacts',
            contact.toJson(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final message in oldStore.messages) {
          await txn.insert(
            'messages',
            message.toJson(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await txn.insert('metadata', {
          'key': 'next_message_counter',
          'value': oldStore.nextMessageCounter.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    } catch (_) {
      // If parsing or database insertion fails, we let it throw or handle it
      rethrow;
    }
  }
}

class AndroidSealedEnvelopeRecord {
  const AndroidSealedEnvelopeRecord({
    required this.envelopeId,
    required this.kind,
    required this.recipientKeyId,
    required this.recipientDisplayName,
    required this.createdAtUnixMs,
    required this.messageCounter,
    this.sourceName,
    required this.payloadSize,
    required this.envelopeSize,
    required this.path,
    this.uri,
    this.displayPath,
    this.mime,
    this.sizeBytes,
    this.deletedAtUnixMs,
  });

  final String envelopeId;
  final String kind;
  final String recipientKeyId;
  final String recipientDisplayName;
  final int createdAtUnixMs;
  final int messageCounter;
  final String? sourceName;
  final int payloadSize;
  final int envelopeSize;
  final String path;
  final String? uri;
  final String? displayPath;
  final String? mime;
  final int? sizeBytes;
  final int? deletedAtUnixMs;

  bool get isFile => kind == 'file' || kind == 'group_file';
  bool get isDeleted => (deletedAtUnixMs ?? 0) > 0;

  String get displayPathOrPath {
    final display = displayPath?.trim() ?? '';
    if (display.isNotEmpty) return display;
    return path;
  }

  String get locationPath {
    final display = displayPathOrPath.trim();
    if (display.isNotEmpty) return display;
    return uri?.trim() ?? '';
  }

  Map<String, Object?> toJson() => {
    'envelope_id': envelopeId,
    'kind': kind,
    'recipient_key_id': recipientKeyId,
    'recipient_display_name': recipientDisplayName,
    'created_at_unix_ms': createdAtUnixMs,
    'message_counter': messageCounter,
    'source_name': sourceName,
    'payload_size': payloadSize,
    'envelope_size': envelopeSize,
    'path': path,
    'uri': uri,
    'display_path': displayPath,
    'mime': mime,
    'size_bytes': sizeBytes,
    'deleted_at_unix_ms': deletedAtUnixMs,
  };

  static AndroidSealedEnvelopeRecord fromJson(Map<String, Object?> json) {
    return AndroidSealedEnvelopeRecord(
      envelopeId: json['envelope_id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'text',
      recipientKeyId: json['recipient_key_id']?.toString() ?? '',
      recipientDisplayName: json['recipient_display_name']?.toString() ?? '',
      createdAtUnixMs: (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      messageCounter: (json['message_counter'] as num?)?.toInt() ?? 0,
      sourceName: json['source_name']?.toString(),
      payloadSize: (json['payload_size'] as num?)?.toInt() ?? 0,
      envelopeSize: (json['envelope_size'] as num?)?.toInt() ?? 0,
      path: json['path']?.toString() ?? '',
      uri: json['uri']?.toString(),
      displayPath: json['display_path']?.toString(),
      mime: json['mime']?.toString(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      deletedAtUnixMs: (json['deleted_at_unix_ms'] as num?)?.toInt(),
    );
  }
}
