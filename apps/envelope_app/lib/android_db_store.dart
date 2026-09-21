import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'android_chat_store.dart';
import 'android_mailbox_reliability.dart';
import 'android_relay_ha_store.dart';

class AndroidDbStore {
  AndroidDbStore._()
    : _databaseFactoryOverride = null,
      _databaseDirectory = null;

  @visibleForTesting
  factory AndroidDbStore.forTesting({
    required DatabaseFactory databaseFactory,
    required String databaseDirectory,
  }) => AndroidDbStore._withDatabase(databaseFactory, databaseDirectory);

  AndroidDbStore._withDatabase(
    this._databaseFactoryOverride,
    this._databaseDirectory,
  );

  final DatabaseFactory? _databaseFactoryOverride;
  final String? _databaseDirectory;

  static final AndroidDbStore instance = AndroidDbStore._();

  Database? _db;
  Future<Database>? _opening;

  bool get isOpen => _db != null;

  AndroidRelayHaStore get relayHa => AndroidRelayHaStore(_getDb());

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
    final factory = _databaseFactoryOverride ?? databaseFactory;
    final dbDir = _databaseDirectory ?? await factory.getDatabasesPath();
    final dbPath = join(dbDir, 'envelope_chat_secure.db');

    return factory.openDatabase(
      dbPath,
      options: SqlCipherOpenDatabaseOptions(
        password: password,
        version: 15,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=FULL');
          final mode = await db.rawQuery('PRAGMA synchronous');
          if (mode.single.values.single != 2) {
            throw StateError('SQLite FULL durability is required');
          }
        },
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
            attachment_deleted_at_unix_ms INTEGER,
            is_read INTEGER NOT NULL DEFAULT 1
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
          await _createPendingEnvelopeTable(db);
          await _createMailboxReliabilityTables(db);
          await AndroidRelayHaStore.createTables(db);
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
          if (oldVersion < 11) {
            await _migrateReceivedMessageCountersToRecipientScope(db);
          }
          if (oldVersion < 12) {
            await _createPendingEnvelopeTable(db);
          }
          if (oldVersion < 13) {
            await _addColumnIfMissing(
              db,
              'messages',
              'is_read',
              'is_read INTEGER NOT NULL DEFAULT 1',
            );
          }
          if (oldVersion < 14) {
            await _addColumnIfMissing(
              db,
              'pending_envelopes',
              'logical_kind',
              "logical_kind TEXT NOT NULL DEFAULT 'message'",
            );
            await _createMailboxReliabilityTables(db);
          }
          if (oldVersion < 15) {
            await AndroidRelayHaStore.createTables(db);
            await db.update(
              'messages',
              {'delivery_status': AndroidDeliveryStatus.legacySent},
              where: 'direction = ? AND delivery_status = ?',
              whereArgs: ['outgoing', AndroidDeliveryStatus.sent],
            );
          }
        },
        onOpen: (db) async {
          await _normalizeMailboxReliability(
            db,
            DateTime.now().millisecondsSinceEpoch,
          );
        },
      ),
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
        recipient_identity_key_id TEXT NOT NULL,
        sender_key_id TEXT NOT NULL,
        message_counter INTEGER NOT NULL,
        conversation_id TEXT NOT NULL,
        envelope_id TEXT NOT NULL,
        first_seen_at_unix_ms INTEGER NOT NULL,
        PRIMARY KEY (
          recipient_identity_key_id,
          sender_key_id,
          message_counter
        )
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_received_message_counters_envelope
      ON received_message_counters(envelope_id)
    ''');
  }

  Future<void> _createPendingEnvelopeTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_envelopes (
        envelope_id TEXT PRIMARY KEY,
        logical_message_id TEXT NOT NULL,
        logical_kind TEXT NOT NULL DEFAULT 'message',
        recipient_key_id TEXT NOT NULL,
        recipient_display_name TEXT NOT NULL,
        recipient_contact_json TEXT NOT NULL,
        envelope_b64 TEXT NOT NULL,
        created_at_unix_ms INTEGER NOT NULL,
        child_index INTEGER NOT NULL,
        child_count INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at_unix_ms INTEGER,
        last_error TEXT,
        delivery_status TEXT NOT NULL,
        last_route TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_pending_envelopes_logical
      ON pending_envelopes(logical_message_id, child_index)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_pending_envelopes_status
      ON pending_envelopes(delivery_status, created_at_unix_ms)
    ''');
  }

  Future<void> _createMailboxReliabilityTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mailbox_quarantine (
        envelope_id TEXT PRIMARY KEY,
        sender_key_id TEXT NOT NULL,
        reason_code TEXT NOT NULL,
        reason_detail TEXT NOT NULL,
        envelope_sha256 TEXT NOT NULL,
        envelope_size_bytes INTEGER NOT NULL,
        quarantined_at_unix_ms INTEGER NOT NULL,
        acknowledged_at_unix_ms INTEGER
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mailbox_quarantine_created
      ON mailbox_quarantine(quarantined_at_unix_ms DESC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deferred_mailbox_envelopes (
        envelope_id TEXT PRIMARY KEY,
        sender_key_id TEXT NOT NULL,
        envelope_b64 TEXT NOT NULL,
        reason_code TEXT NOT NULL,
        reason_detail TEXT NOT NULL,
        envelope_size_bytes INTEGER NOT NULL,
        first_deferred_at_unix_ms INTEGER NOT NULL,
        last_attempt_at_unix_ms INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_deferred_mailbox_created
      ON deferred_mailbox_envelopes(first_deferred_at_unix_ms ASC)
    ''');
  }

  Future<void> _backfillReceivedMessageCounters(DatabaseExecutor db) async {
    await db.execute('''
      INSERT OR IGNORE INTO received_message_counters (
        recipient_identity_key_id,
        sender_key_id,
        message_counter,
        conversation_id,
        envelope_id,
        first_seen_at_unix_ms
      )
      SELECT
        '',
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

  Future<void> _migrateReceivedMessageCountersToRecipientScope(
    DatabaseExecutor db,
  ) async {
    final columns = await db.rawQuery(
      'PRAGMA table_info(received_message_counters)',
    );
    if (columns.isEmpty) {
      await _createReceivedMessageCounterTable(db);
      await _backfillReceivedMessageCounters(db);
      return;
    }
    if (columns.any(
      (row) => row['name']?.toString() == 'recipient_identity_key_id',
    )) {
      return;
    }
    await db.execute(
      'ALTER TABLE received_message_counters '
      'RENAME TO received_message_counters_v10',
    );
    await db.execute(
      'DROP INDEX IF EXISTS idx_received_message_counters_envelope',
    );
    await _createReceivedMessageCounterTable(db);
    await db.execute('''
      INSERT OR IGNORE INTO received_message_counters (
        recipient_identity_key_id,
        sender_key_id,
        message_counter,
        conversation_id,
        envelope_id,
        first_seen_at_unix_ms
      )
      SELECT
        '',
        sender_key_id,
        message_counter,
        conversation_id,
        envelope_id,
        first_seen_at_unix_ms
      FROM received_message_counters_v10
    ''');
    await db.execute('DROP TABLE received_message_counters_v10');
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

  /// Group membership and an already sealed fanout may retain an authenticated
  /// contact without adding it to the personal address book.
  Future<AndroidContactRecord?> getKnownContact(String keyId) async {
    final direct = await getContact(keyId);
    if (direct != null) return direct;
    final members = await _getDb().query(
      'group_members',
      where: "key_id = ? AND contact_json <> ''",
      whereArgs: [keyId],
      limit: 1,
    );
    if (members.isNotEmpty) {
      return AndroidGroupMemberRecord.fromJson(
        members.single,
      ).toContactRecord();
    }
    final pending = await _getDb().query(
      'pending_envelopes',
      where: "recipient_key_id = ? AND recipient_contact_json <> ''",
      whereArgs: [keyId],
      limit: 1,
    );
    return pending.isEmpty
        ? null
        : AndroidPendingEnvelopeRecord.fromJson(
            pending.single,
          ).toContactRecord();
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
        AND is_read = 0
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
        AND is_read = 0
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

  Future<bool> addMessage(
    AndroidMessageRecord message, {
    String? recipientIdentityKeyId,
    bool createRelayResult = false,
  }) async {
    final db = _getDb();
    return db.transaction(
      (txn) => _addMessageInExecutor(
        txn,
        message,
        recipientIdentityKeyId: recipientIdentityKeyId,
        createRelayResult: createRelayResult,
      ),
    );
  }

  Future<bool> _addMessageInExecutor(
    DatabaseExecutor txn,
    AndroidMessageRecord message, {
    String? recipientIdentityKeyId,
    bool createRelayResult = false,
  }) async {
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
      final recipientKeyId = recipientIdentityKeyId?.trim() ?? '';
      if (recipientKeyId.isEmpty) {
        throw ArgumentError.value(
          recipientIdentityKeyId,
          'recipientIdentityKeyId',
          'is required for an incoming message',
        );
      }
      final counterInserted = await _recordReceivedMessageCounter(
        txn,
        message,
        recipientKeyId,
      );
      if (!counterInserted) {
        throw AndroidMessageCounterReplayException(
          '检测到重放计数器：${message.peerKeyId} / '
          '${message.messageCounter}。',
        );
      }
    }
    await txn.insert('messages', message.toJson());
    if (createRelayResult && message.direction == 'incoming') {
      await AndroidRelayHaStore.recordOutcomeInTransaction(
        txn,
        senderKeyId: message.peerKeyId,
        recipientKeyId: recipientIdentityKeyId!,
        envelopeId: message.envelopeId,
        envelopeBase64: message.opaqueEnvelopeBase64,
        receivedAt: message.createdAtUnixMs,
      );
    }
    return true;
  }

  Future<bool> _recordReceivedMessageCounter(
    DatabaseExecutor db,
    AndroidMessageRecord message,
    String recipientIdentityKeyId,
  ) async {
    final senderKeyId = message.peerKeyId.trim();
    final conversationId = message.conversationId.trim();
    if (!message.hasTrackableIncomingCounter) {
      return false;
    }
    final existing = await db.query(
      'received_message_counters',
      columns: ['envelope_id'],
      where:
          'recipient_identity_key_id = ? AND sender_key_id = ? AND message_counter = ?',
      whereArgs: [recipientIdentityKeyId, senderKeyId, message.messageCounter],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;
    await db.insert('received_message_counters', {
      'recipient_identity_key_id': recipientIdentityKeyId,
      'sender_key_id': senderKeyId,
      'message_counter': message.messageCounter,
      'conversation_id': conversationId,
      'envelope_id': message.envelopeId,
      'first_seen_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
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

  Future<int> markIncomingMessagesRead({
    String? peerKeyId,
    String? conversationId,
  }) async {
    final normalizedPeerKeyId = peerKeyId?.trim() ?? '';
    final normalizedConversationId = conversationId?.trim() ?? '';
    if (normalizedPeerKeyId.isEmpty && normalizedConversationId.isEmpty) {
      throw const FormatException(
        'read marker requires a peer or conversation',
      );
    }
    final clauses = <String>['direction = ?', 'is_read = 0'];
    final args = <Object?>['incoming'];
    if (normalizedPeerKeyId.isNotEmpty) {
      clauses.add('peer_key_id = ?');
      clauses.add('conversation_id NOT IN (SELECT group_id FROM groups)');
      args.add(normalizedPeerKeyId);
    }
    if (normalizedConversationId.isNotEmpty) {
      clauses.add('conversation_id = ?');
      args.add(normalizedConversationId);
    }
    final db = _getDb();
    return db.update(
      'messages',
      {'is_read': 1},
      where: clauses.join(' AND '),
      whereArgs: args,
    );
  }

  Future<void> stageOutboundEnvelopeBatch({
    required AndroidMessageRecord logicalMessage,
    required List<AndroidPendingEnvelopeRecord> children,
    AndroidGroupEventRecord? groupEvent,
  }) async {
    if (children.isEmpty) {
      throw ArgumentError.value(children, 'children', 'must not be empty');
    }
    final logicalMessageId = logicalMessage.envelopeId.trim();
    if (logicalMessageId.isEmpty ||
        children.any(
          (child) =>
              child.logicalMessageId != logicalMessageId ||
              child.logicalKind != AndroidPendingEnvelopeKind.message ||
              child.childCount != children.length ||
              child.childIndex < 0 ||
              child.childIndex >= children.length,
        ) ||
        children.map((child) => child.childIndex).toSet().length !=
            children.length) {
      throw const FormatException(
        'outbound envelope batch metadata is invalid',
      );
    }

    final db = _getDb();
    await db.transaction((txn) async {
      await txn.insert(
        'messages',
        logicalMessage.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (groupEvent != null) {
        await txn.insert(
          'group_events',
          groupEvent.toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final child in children) {
        await txn.insert(
          'pending_envelopes',
          child.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> stageGroupControlTransition({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required AndroidGroupEventRecord event,
    required List<AndroidPendingEnvelopeRecord> children,
  }) async {
    final logicalMessageId = 'group-event:${event.eventId}';
    final memberKeys = members.map((member) => member.keyId).toSet();
    final childrenValid =
        children.isEmpty ||
        (children.every(
              (child) =>
                  child.logicalMessageId == logicalMessageId &&
                  child.logicalKind ==
                      AndroidPendingEnvelopeKind.groupControl &&
                  child.childCount == children.length &&
                  child.childIndex >= 0 &&
                  child.childIndex < children.length &&
                  memberKeys.contains(child.recipientKeyId),
            ) &&
            children.map((child) => child.childIndex).toSet().length ==
                children.length);
    if (group.groupId.trim().isEmpty ||
        event.eventId.trim().isEmpty ||
        event.groupId != group.groupId ||
        event.epoch != group.epoch ||
        members.isEmpty ||
        members.any((member) => member.groupId != group.groupId) ||
        memberKeys.length != members.length ||
        !childrenValid) {
      throw const FormatException(
        'group control transition metadata is invalid',
      );
    }

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
      for (final child in children) {
        await txn.insert(
          'pending_envelopes',
          child.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Group effects, the visible event and the replay counter commit together.
  /// A failed import must not advance the epoch used by the causal retry queue.
  Future<bool> importGroupControlTransition({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required AndroidGroupEventRecord event,
    required AndroidMessageRecord message,
    required String recipientIdentityKeyId,
    bool createRelayResult = false,
  }) async {
    if (event.groupId != group.groupId ||
        message.direction != 'incoming' ||
        members.any((member) => member.groupId != group.groupId)) {
      throw const AndroidInvalidEnvelopePayloadException('群组入站事务的群或消息标识不一致。');
    }
    return _getDb().transaction((txn) async {
      final inserted = await _addMessageInExecutor(
        txn,
        message,
        recipientIdentityKeyId: recipientIdentityKeyId,
        createRelayResult: createRelayResult,
      );
      if (!inserted) return false;
      final existingEvents = await txn.query(
        'group_events',
        where: 'event_id = ?',
        whereArgs: [event.eventId],
        limit: 1,
      );
      if (existingEvents.isNotEmpty) {
        final existing = AndroidGroupEventRecord.fromJson(existingEvents.first);
        if (existing.groupId != event.groupId ||
            existing.epoch != event.epoch ||
            existing.type != event.type ||
            existing.actorKeyId != event.actorKeyId ||
            existing.createdAtUnixMs != event.createdAtUnixMs ||
            existing.signature != event.signature) {
          throw const AndroidInvalidEnvelopePayloadException(
            '同一群事件 id 对应不同的已签名事件。',
          );
        }
        // A stable event can arrive over more than one transport. Preserve
        // its replay record without reapplying an older membership snapshot.
        return true;
      }
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
      await txn.insert('group_events', event.toJson());
      return true;
    });
  }

  Future<String> logicalMessageIdForEnvelope(String envelopeId) async {
    final db = _getDb();
    final pending = await db.query(
      'pending_envelopes',
      columns: ['logical_message_id'],
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    if (pending.isNotEmpty) {
      return pending.single['logical_message_id'] as String;
    }
    final transfer = await db.rawQuery(
      '''
      SELECT message_envelope_id FROM file_transfers
      WHERE manifest_envelope_id = ? OR transfer_id IN
        (SELECT transfer_id FROM file_transfer_chunks WHERE envelope_id = ?)
      LIMIT 1
    ''',
      [envelopeId, envelopeId],
    );
    return transfer.isNotEmpty &&
            transfer.single['message_envelope_id'] is String
        ? transfer.single['message_envelope_id'] as String
        : envelopeId;
  }

  Future<List<AndroidPendingEnvelopeRecord>> getPendingEnvelopes() async {
    final db = _getDb();
    final maps = await db.query(
      'pending_envelopes',
      where: 'delivery_status = ? AND envelope_b64 <> ?',
      whereArgs: [AndroidDeliveryStatus.pending, ''],
      orderBy: 'created_at_unix_ms ASC, child_index ASC',
    );
    return maps
        .map((map) => AndroidPendingEnvelopeRecord.fromJson(map))
        .toList(growable: false);
  }

  Future<List<AndroidPendingEnvelopeRecord>> getOutboundEnvelopeBatch(
    String logicalMessageId,
  ) async {
    final db = _getDb();
    final maps = await db.query(
      'pending_envelopes',
      where: 'logical_message_id = ?',
      whereArgs: [logicalMessageId],
      orderBy: 'child_index ASC',
    );
    return maps
        .map((map) => AndroidPendingEnvelopeRecord.fromJson(map))
        .toList(growable: false);
  }

  Future<Set<String>> getStagedOutboundLogicalMessageIds() async {
    final db = _getDb();
    final maps = await db.query(
      'pending_envelopes',
      columns: ['logical_message_id'],
      distinct: true,
    );
    return maps
        .map((map) => map['logical_message_id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<int> getPendingGroupControlCount() async {
    final db = _getDb();
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(DISTINCT logical_message_id) AS total
      FROM pending_envelopes
      WHERE logical_kind = ? AND delivery_status = ? AND envelope_b64 <> ''
      ''',
      [AndroidPendingEnvelopeKind.groupControl, AndroidDeliveryStatus.pending],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<void> updatePendingEnvelopeDelivery({
    required String envelopeId,
    required String deliveryStatus,
    required String detail,
    required String route,
  }) async {
    final db = _getDb();
    final pending = deliveryStatus == AndroidDeliveryStatus.pending;
    await db.rawUpdate(
      '''
      UPDATE pending_envelopes
      SET attempt_count = attempt_count + 1,
          next_attempt_at_unix_ms = ?,
          last_error = ?,
          delivery_status = ?,
          last_route = ?,
          envelope_b64 = CASE WHEN ? THEN envelope_b64 ELSE '' END
      WHERE envelope_id = ?
      ''',
      [
        pending
            ? DateTime.now()
                  .add(const Duration(seconds: 30))
                  .millisecondsSinceEpoch
            : null,
        pending ? detail : null,
        deliveryStatus,
        route,
        pending ? 1 : 0,
        envelopeId,
      ],
    );
  }

  Future<int> deleteOutboundEnvelopeBatch(String logicalMessageId) async {
    final db = _getDb();
    return db.delete(
      'pending_envelopes',
      where: 'logical_message_id = ?',
      whereArgs: [logicalMessageId],
    );
  }

  Future<AndroidMailboxReliabilityNormalization> pruneMailboxReliability({
    int? nowUnixMs,
  }) {
    return _normalizeMailboxReliability(
      _getDb(),
      nowUnixMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<AndroidMailboxQuarantineRecord?> getMailboxQuarantine(
    String envelopeId,
  ) async {
    final db = _getDb();
    final rows = await db.query(
      'mailbox_quarantine',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : AndroidMailboxQuarantineRecord.fromJson(rows.first);
  }

  Future<AndroidDeferredMailboxEnvelopeRecord?> getDeferredMailboxEnvelope(
    String envelopeId,
  ) async {
    final db = _getDb();
    final rows = await db.query(
      'deferred_mailbox_envelopes',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : AndroidDeferredMailboxEnvelopeRecord.fromJson(rows.first);
  }

  Future<List<AndroidDeferredMailboxEnvelopeRecord>>
  getDeferredMailboxEnvelopes() async {
    final db = _getDb();
    final rows = await db.query(
      'deferred_mailbox_envelopes',
      orderBy: 'first_deferred_at_unix_ms ASC, envelope_id ASC',
    );
    return rows
        .map(AndroidDeferredMailboxEnvelopeRecord.fromJson)
        .toList(growable: false);
  }

  Future<void> addMailboxQuarantine({
    required String envelopeId,
    required String senderKeyId,
    required String reasonCode,
    required String reasonDetail,
    required String envelopeBase64,
    required int quarantinedAtUnixMs,
    bool alreadyAcknowledged = false,
    String? recipientIdentityKeyId,
  }) async {
    final record = AndroidMailboxQuarantineRecord(
      envelopeId: envelopeId,
      senderKeyId: senderKeyId,
      reasonCode: reasonCode,
      reasonDetail: sanitizeAndroidMailboxFailureDetail(reasonDetail),
      envelopeSha256: androidMailboxEnvelopeSha256(envelopeBase64),
      envelopeSizeBytes: androidMailboxEnvelopeSizeBytes(envelopeBase64),
      quarantinedAtUnixMs: quarantinedAtUnixMs,
      acknowledgedAtUnixMs: alreadyAcknowledged ? quarantinedAtUnixMs : null,
    );
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.insert(
        'mailbox_quarantine',
        record.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _normalizeMailboxReliabilityInExecutor(txn, quarantinedAtUnixMs);
      if (recipientIdentityKeyId != null) {
        await AndroidRelayHaStore.recordOutcomeInTransaction(
          txn,
          senderKeyId: senderKeyId,
          recipientKeyId: recipientIdentityKeyId,
          envelopeId: envelopeId,
          envelopeBase64: envelopeBase64,
          receivedAt: quarantinedAtUnixMs,
          outcome: 'rejected',
          reasonCode: reasonCode.toUpperCase(),
        );
      }
    });
  }

  Future<bool> stageDeferredMailboxEnvelope({
    required String envelopeId,
    required String senderKeyId,
    required String envelopeBase64,
    required String reasonCode,
    required String reasonDetail,
    required int nowUnixMs,
    String? recipientIdentityKeyId,
  }) async {
    final size = androidMailboxEnvelopeSizeBytes(envelopeBase64);
    final db = _getDb();
    return db.transaction((txn) async {
      if (size <= 0 || size > androidMaximumDeferredMailboxEnvelopeBytes) {
        final quarantine = AndroidMailboxQuarantineRecord(
          envelopeId: envelopeId,
          senderKeyId: senderKeyId,
          reasonCode: 'deferred_payload_too_large',
          reasonDetail: sanitizeAndroidMailboxFailureDetail(
            '需要因果前置的 mailbox 信封为 $size bytes，超过 '
            '$androidMaximumDeferredMailboxEnvelopeBytes bytes 上限。',
          ),
          envelopeSha256: androidMailboxEnvelopeSha256(envelopeBase64),
          envelopeSizeBytes: size,
          quarantinedAtUnixMs: nowUnixMs,
        );
        await txn.insert(
          'mailbox_quarantine',
          quarantine.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await _normalizeMailboxReliabilityInExecutor(txn, nowUnixMs);
        return false;
      }

      final existingRows = await txn.query(
        'deferred_mailbox_envelopes',
        where: 'envelope_id = ?',
        whereArgs: [envelopeId],
        limit: 1,
      );
      final existing = existingRows.isEmpty
          ? null
          : AndroidDeferredMailboxEnvelopeRecord.fromJson(existingRows.first);
      final record = existing == null
          ? AndroidDeferredMailboxEnvelopeRecord(
              envelopeId: envelopeId,
              senderKeyId: senderKeyId,
              envelopeBase64: envelopeBase64,
              reasonCode: reasonCode,
              reasonDetail: sanitizeAndroidMailboxFailureDetail(reasonDetail),
              envelopeSizeBytes: size,
              firstDeferredAtUnixMs: nowUnixMs,
              lastAttemptAtUnixMs: nowUnixMs,
            )
          : existing.copyWith(
              senderKeyId: senderKeyId,
              envelopeBase64: envelopeBase64,
              reasonCode: reasonCode,
              reasonDetail: sanitizeAndroidMailboxFailureDetail(reasonDetail),
              envelopeSizeBytes: size,
              lastAttemptAtUnixMs: nowUnixMs,
              attemptCount: existing.attemptCount >= 0x7fffffff
                  ? 0x7fffffff
                  : existing.attemptCount + 1,
            );
      await txn.insert(
        'deferred_mailbox_envelopes',
        record.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _normalizeMailboxReliabilityInExecutor(txn, nowUnixMs);
      final retained = await txn.query(
        'deferred_mailbox_envelopes',
        columns: ['envelope_id'],
        where: 'envelope_id = ?',
        whereArgs: [envelopeId],
        limit: 1,
      );
      if (retained.isNotEmpty && recipientIdentityKeyId != null) {
        await AndroidRelayHaStore.recordOutcomeInTransaction(
          txn,
          senderKeyId: senderKeyId,
          recipientKeyId: recipientIdentityKeyId,
          envelopeId: envelopeId,
          envelopeBase64: envelopeBase64,
          receivedAt: nowUnixMs,
          outcome: 'deferred',
          reasonCode: 'MISSING_PREREQUISITE',
        );
      }
      return retained.isNotEmpty;
    });
  }

  Future<void> deleteDeferredMailboxEnvelope(String envelopeId) async {
    await _getDb().delete(
      'deferred_mailbox_envelopes',
      where: 'envelope_id = ?',
      whereArgs: [envelopeId],
    );
  }

  Future<void> updateDeferredMailboxFailure({
    required AndroidDeferredMailboxEnvelopeRecord record,
    required String reasonCode,
    required String reasonDetail,
    required int attemptedAtUnixMs,
  }) async {
    await _getDb().update(
      'deferred_mailbox_envelopes',
      {
        'reason_code': reasonCode,
        'reason_detail': sanitizeAndroidMailboxFailureDetail(reasonDetail),
        'last_attempt_at_unix_ms': attemptedAtUnixMs,
        'attempt_count': record.attemptCount >= 0x7fffffff
            ? 0x7fffffff
            : record.attemptCount + 1,
      },
      where: 'envelope_id = ?',
      whereArgs: [record.envelopeId],
    );
  }

  Future<void> moveDeferredMailboxEnvelopeToQuarantine({
    required AndroidDeferredMailboxEnvelopeRecord record,
    required String reasonCode,
    required String reasonDetail,
    required int quarantinedAtUnixMs,
    String? recipientIdentityKeyId,
  }) async {
    final quarantine = AndroidMailboxQuarantineRecord(
      envelopeId: record.envelopeId,
      senderKeyId: record.senderKeyId,
      reasonCode: reasonCode,
      reasonDetail: sanitizeAndroidMailboxFailureDetail(reasonDetail),
      envelopeSha256: androidMailboxEnvelopeSha256(record.envelopeBase64),
      envelopeSizeBytes: androidMailboxEnvelopeSizeBytes(record.envelopeBase64),
      quarantinedAtUnixMs: quarantinedAtUnixMs,
      acknowledgedAtUnixMs: quarantinedAtUnixMs,
    );
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.delete(
        'deferred_mailbox_envelopes',
        where: 'envelope_id = ?',
        whereArgs: [record.envelopeId],
      );
      await txn.insert(
        'mailbox_quarantine',
        quarantine.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _normalizeMailboxReliabilityInExecutor(txn, quarantinedAtUnixMs);
      if (recipientIdentityKeyId != null) {
        await AndroidRelayHaStore.recordOutcomeInTransaction(
          txn,
          senderKeyId: record.senderKeyId,
          recipientKeyId: recipientIdentityKeyId,
          envelopeId: record.envelopeId,
          envelopeBase64: record.envelopeBase64,
          receivedAt: quarantinedAtUnixMs,
          outcome: 'rejected',
          reasonCode: reasonCode.toUpperCase(),
        );
      }
    });
  }

  Future<void> markMailboxQuarantineAcknowledged({
    required Iterable<String> envelopeIds,
    required int acknowledgedAtUnixMs,
  }) async {
    final ids = envelopeIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;
    await _getDb().update(
      'mailbox_quarantine',
      {'acknowledged_at_unix_ms': acknowledgedAtUnixMs},
      where: 'envelope_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<AndroidMailboxReliabilityNormalization> _normalizeMailboxReliability(
    Database db,
    int nowUnixMs,
  ) {
    return db.transaction(
      (txn) => _normalizeMailboxReliabilityInExecutor(txn, nowUnixMs),
    );
  }

  Future<AndroidMailboxReliabilityNormalization>
  _normalizeMailboxReliabilityInExecutor(
    DatabaseExecutor db,
    int nowUnixMs,
  ) async {
    final quarantineRows = await db.query('mailbox_quarantine');
    final deferredRows = await db.query('deferred_mailbox_envelopes');
    final normalized = normalizeAndroidMailboxReliability(
      quarantine: quarantineRows.map(AndroidMailboxQuarantineRecord.fromJson),
      deferred: deferredRows.map(AndroidDeferredMailboxEnvelopeRecord.fromJson),
      nowUnixMs: nowUnixMs,
    );
    final quarantineById = {
      for (final row in quarantineRows)
        row['envelope_id']: AndroidMailboxQuarantineRecord.fromJson(row),
    };
    final retainedQuarantineIds = normalized.quarantine
        .map((record) => record.envelopeId)
        .toSet();
    final retainedDeferredIds = normalized.deferred
        .map((record) => record.envelopeId)
        .toSet();
    for (final row in quarantineRows) {
      if (!retainedQuarantineIds.contains(row['envelope_id'])) {
        await db.delete(
          'mailbox_quarantine',
          where: 'envelope_id = ?',
          whereArgs: [row['envelope_id']],
        );
      }
    }
    for (final row in deferredRows) {
      if (!retainedDeferredIds.contains(row['envelope_id'])) {
        final outcomes = await db.query(
          'relay_ha_result_outbox',
          columns: ['recipient_key_id'],
          where:
              "sender_key_id = ? AND envelope_id = ? AND outcome = 'deferred'",
          whereArgs: [row['sender_key_id'], row['envelope_id']],
        );
        for (final outcome in outcomes) {
          await AndroidRelayHaStore.recordOutcomeInTransaction(
            db,
            senderKeyId: row['sender_key_id'] as String,
            recipientKeyId: outcome['recipient_key_id'] as String,
            envelopeId: row['envelope_id'] as String,
            envelopeBase64: row['envelope_b64'] as String,
            receivedAt: nowUnixMs,
            outcome: 'rejected',
            reasonCode: 'DEFERRED_RETENTION_ENDED',
          );
        }
        await db.delete(
          'deferred_mailbox_envelopes',
          where: 'envelope_id = ?',
          whereArgs: [row['envelope_id']],
        );
      }
    }
    for (final record in normalized.quarantine) {
      final existing = quarantineById[record.envelopeId];
      if (existing != null &&
          jsonEncode(existing.toJson()) == jsonEncode(record.toJson())) {
        continue;
      }
      await db.insert(
        'mailbox_quarantine',
        record.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    return normalized;
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
      await txn.delete(
        'pending_envelopes',
        where: 'logical_message_id IN ($placeholders)',
        whereArgs: normalizedIds,
      );
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

  Future<List<AndroidGroupEventRecord>> getPortableGroupEvents() async {
    final db = _getDb();
    final maps = await db.query(
      'group_events',
      orderBy: 'group_id ASC, epoch ASC, created_at_unix_ms ASC, event_id ASC',
      limit: androidMaximumPortableGroupEvents + 1,
    );
    return androidNormalizePortableGroupEvents(
      maps.map(AndroidGroupEventRecord.fromJson),
    );
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
    return (await getCounterLaneState()).nextMessageCounter;
  }

  Future<void> setNextMessageCounter(int counter) async {
    final db = _getDb();
    final lane = await getCounterLaneState();
    if (!androidHasValidCounterLane(
          nextMessageCounter: counter,
          counterNamespace: lane.counterNamespace,
          counterNamespaceBits: lane.counterNamespaceBits,
        ) ||
        counter < lane.nextMessageCounter) {
      throw ArgumentError.value(
        counter,
        'counter',
        'must advance the current namespaced counter lane',
      );
    }
    await _writeMetadata(db, 'next_message_counter', counter.toString());
  }

  Future<AndroidChatStore> getCounterLaneState() async {
    final db = _getDb();
    return db.transaction((txn) async {
      final metadata = await _readMetadata(txn, const {
        'next_message_counter',
        'counter_namespace',
        'counter_namespace_bits',
        'counter_device_id',
        'counter_retired_namespaces',
      });
      final nextCounter =
          int.tryParse(metadata['next_message_counter'] ?? '') ?? 1;
      final counterNamespace =
          int.tryParse(metadata['counter_namespace'] ?? '') ?? 0;
      final counterNamespaceBits =
          int.tryParse(metadata['counter_namespace_bits'] ?? '') ?? 0;
      final counterDeviceId = metadata['counter_device_id']?.trim() ?? '';
      final retired = _parseRetiredCounterNamespaces(
        metadata['counter_retired_namespaces'],
      );
      final current = AndroidChatStore.empty().copyWith(
        nextMessageCounter: nextCounter,
        counterNamespace: counterNamespace,
        counterNamespaceBits: counterNamespaceBits,
        counterDeviceId: counterDeviceId,
        retiredCounterNamespaces: retired.toList(),
      );
      if (current.hasValidCounterLane && counterDeviceId.isNotEmpty) {
        return current.normalized();
      }

      final excluded = androidCounterNamespacesToExclude([current]);
      final newNamespace = _randomCounterNamespace(excluded);
      final highWater = androidMessageCounterSequence(nextCounter);
      final nextSequence =
          highWater <=
              androidMaximumMessageCounterSequence -
                  androidPortableRestoreCounterReservation
          ? (highWater + androidPortableRestoreCounterReservation)
                .clamp(1, androidMaximumMessageCounterSequence)
                .toInt()
          : 1;
      final migrated = current
          .copyWith(
            nextMessageCounter: androidComposeMessageCounter(
              nextSequence,
              newNamespace,
            ),
            counterNamespace: newNamespace,
            counterNamespaceBits: androidMessageCounterNamespaceBits,
            counterDeviceId: _randomCounterDeviceId(),
            retiredCounterNamespaces: excluded.toList(),
          )
          .normalized();
      await _writeCounterLaneMetadata(txn, migrated);
      return migrated;
    });
  }

  Future<void> bindLegacyReceivedCountersToIdentity(
    String recipientIdentityKeyId,
  ) async {
    final recipientKeyId = recipientIdentityKeyId.trim();
    if (recipientKeyId.isEmpty) {
      throw ArgumentError.value(
        recipientIdentityKeyId,
        'recipientIdentityKeyId',
      );
    }
    final db = _getDb();
    await db.transaction((txn) async {
      await txn.execute(
        '''
        INSERT OR IGNORE INTO received_message_counters (
          recipient_identity_key_id,
          sender_key_id,
          message_counter,
          conversation_id,
          envelope_id,
          first_seen_at_unix_ms
        )
        SELECT
          ?,
          sender_key_id,
          message_counter,
          conversation_id,
          envelope_id,
          first_seen_at_unix_ms
        FROM received_message_counters
        WHERE recipient_identity_key_id = ''
      ''',
        [recipientKeyId],
      );
      await txn.delete(
        'received_message_counters',
        where: "recipient_identity_key_id = ''",
      );
    });
  }

  Future<List<AndroidReceivedCounterRanges>> getReceivedCounterRanges(
    String recipientIdentityKeyId,
  ) async {
    final recipientKeyId = recipientIdentityKeyId.trim();
    if (recipientKeyId.isEmpty) return const [];
    final db = _getDb();
    final rows = await db.query(
      'received_message_counters',
      columns: ['sender_key_id', 'message_counter'],
      where: 'recipient_identity_key_id = ?',
      whereArgs: [recipientKeyId],
      orderBy: 'sender_key_id ASC, message_counter ASC',
    );
    final counters = <AndroidReceivedCounterRanges>[];
    String? senderKeyId;
    var ranges = <AndroidReceivedCounterRange>[];
    int? start;
    int? end;

    void flushRange() {
      if (start != null && end != null) {
        ranges.add(AndroidReceivedCounterRange(start!, end!));
      }
      start = null;
      end = null;
    }

    void flushSender() {
      flushRange();
      if (senderKeyId != null && ranges.isNotEmpty) {
        counters.add(
          AndroidReceivedCounterRanges(
            senderKeyId: senderKeyId,
            ranges: List.unmodifiable(ranges),
          ),
        );
      }
      ranges = <AndroidReceivedCounterRange>[];
    }

    for (final row in rows) {
      final nextSender = row['sender_key_id']?.toString() ?? '';
      final nextCounter = row['message_counter'] as int?;
      if (nextSender.isEmpty || nextCounter == null || nextCounter <= 0) {
        continue;
      }
      if (senderKeyId != nextSender) {
        flushSender();
        senderKeyId = nextSender;
      }
      if (start == null) {
        start = nextCounter;
        end = nextCounter;
      } else if (end! < androidMaximumMessageCounter &&
          nextCounter == end! + 1) {
        end = nextCounter;
      } else if (nextCounter != end) {
        flushRange();
        start = nextCounter;
        end = nextCounter;
      }
    }
    flushSender();
    return androidNormalizeReceivedCounterRanges(counters);
  }

  Future<AndroidChatStore> exportLocalBackupStore({
    required String recipientIdentityKeyId,
    bool includeMessages = false,
  }) async {
    final recipientKeyId = recipientIdentityKeyId.trim();
    if (recipientKeyId.isEmpty) {
      throw ArgumentError.value(
        recipientIdentityKeyId,
        'recipientIdentityKeyId',
      );
    }
    await bindLegacyReceivedCountersToIdentity(recipientKeyId);
    final lane = await getCounterLaneState();
    return AndroidChatStore(
      contacts: await getContacts(),
      messages: includeMessages ? await getMessages() : const [],
      groups: await getGroups(),
      groupMembers: await getGroupMembers(),
      groupEvents: await getPortableGroupEvents(),
      nextMessageCounter: lane.nextMessageCounter,
      counterNamespace: lane.counterNamespace,
      counterNamespaceBits: lane.counterNamespaceBits,
      counterDeviceId: lane.counterDeviceId,
      receivedCounterRecipientKeyId: recipientKeyId,
      receivedCounterRanges: await getReceivedCounterRanges(recipientKeyId),
      retiredCounterNamespaces: lane.retiredCounterNamespaces,
    ).normalized();
  }

  Future<void> importLocalBackupStore(
    AndroidChatStore store, {
    required String recipientIdentityKeyId,
  }) async {
    final db = _getDb();
    final normalized = store.normalized();
    final recipientKeyId = recipientIdentityKeyId.trim();
    if (recipientKeyId.isEmpty ||
        normalized.receivedCounterRecipientKeyId?.trim() != recipientKeyId ||
        !normalized.hasValidCounterLane ||
        (normalized.counterDeviceId?.trim().isEmpty ?? true)) {
      throw const FormatException(
        'portable backup restore state is not bound to a fresh counter endpoint',
      );
    }
    await db.transaction((txn) async {
      final localMetadata = await _readMetadata(txn, const {
        'counter_namespace',
        'counter_retired_namespaces',
      });
      final retired = <int>{
        ..._parseRetiredCounterNamespaces(
          localMetadata['counter_retired_namespaces'],
        ),
        ...normalized.retiredCounterNamespaces,
      };
      final localNamespace =
          int.tryParse(localMetadata['counter_namespace'] ?? '') ?? 0;
      if (localNamespace > 0 &&
          localNamespace <= androidMessageCounterNamespaceMask &&
          localNamespace != normalized.counterNamespace) {
        retired.add(localNamespace);
      }
      await txn.delete('contacts');
      await txn.delete('messages');
      await txn.delete('pending_envelopes');
      await txn.delete('relay_ha_outbox');
      await txn.delete('relay_ha_result_outbox');
      await txn.delete('relay_ha_file_parts');
      await txn.delete('mailbox_quarantine');
      await txn.delete('deferred_mailbox_envelopes');
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
      for (final event in normalized.groupEvents) {
        await txn.insert(
          'group_events',
          event.toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final message in normalized.messages) {
        await txn.insert(
          'messages',
          (message.isOutgoing &&
                      message.deliveryStatus == AndroidDeliveryStatus.sent
                  ? message.copyWith(
                      deliveryStatus: AndroidDeliveryStatus.legacySent,
                    )
                  : message)
              .toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _writeCounterLaneMetadata(
        txn,
        normalized.copyWith(retiredCounterNamespaces: retired.toList()),
      );
      await _insertReceivedCounterRanges(
        txn,
        recipientKeyId,
        normalized.receivedCounterRanges,
      );
    });
  }

  Future<Map<String, String>> _readMetadata(
    DatabaseExecutor db,
    Set<String> keys,
  ) async {
    if (keys.isEmpty) return const {};
    final ordered = keys.toList();
    final rows = await db.query(
      'metadata',
      columns: ['key', 'value'],
      where: 'key IN (${List.filled(ordered.length, '?').join(',')})',
      whereArgs: ordered,
    );
    return {
      for (final row in rows)
        if (row['key'] != null && row['value'] != null)
          row['key'].toString(): row['value'].toString(),
    };
  }

  Future<void> _writeMetadata(
    DatabaseExecutor db,
    String key,
    String value,
  ) async {
    await db.insert('metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _writeCounterLaneMetadata(
    DatabaseExecutor db,
    AndroidChatStore lane,
  ) async {
    if (!lane.hasValidCounterLane ||
        (lane.counterDeviceId?.trim().isEmpty ?? true)) {
      throw const FormatException('counter lane metadata is invalid');
    }
    await _writeMetadata(
      db,
      'next_message_counter',
      lane.nextMessageCounter.toString(),
    );
    await _writeMetadata(
      db,
      'counter_namespace',
      lane.counterNamespace.toString(),
    );
    await _writeMetadata(
      db,
      'counter_namespace_bits',
      lane.counterNamespaceBits.toString(),
    );
    await _writeMetadata(db, 'counter_device_id', lane.counterDeviceId!.trim());
    await _writeMetadata(
      db,
      'counter_retired_namespaces',
      jsonEncode(lane.retiredCounterNamespaces),
    );
  }

  Set<int> _parseRetiredCounterNamespaces(String? json) {
    if (json == null || json.trim().isEmpty) return <int>{};
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return <int>{};
      return decoded
          .whereType<num>()
          .map((value) => value.toInt())
          .where(
            (value) => value > 0 && value <= androidMessageCounterNamespaceMask,
          )
          .toSet();
    } catch (_) {
      return <int>{};
    }
  }

  int _randomCounterNamespace(Set<int> excluded) {
    final random = Random.secure();
    int value;
    do {
      value = (random.nextInt(1 << 16) << 16) | random.nextInt(1 << 16);
    } while (value == 0 || excluded.contains(value));
    return value;
  }

  String _randomCounterDeviceId() {
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'android-$suffix';
  }

  Future<void> _insertReceivedCounterRanges(
    DatabaseExecutor db,
    String recipientIdentityKeyId,
    List<AndroidReceivedCounterRanges> counters,
  ) async {
    final normalized = androidNormalizeReceivedCounterRanges(counters);
    final firstSeenAt = DateTime.now().millisecondsSinceEpoch;
    var batch = db.batch();
    var batchCount = 0;
    for (final sender in normalized) {
      for (final range in sender.ranges) {
        for (var counter = range.start; ; counter += 1) {
          batch.insert(
            'received_message_counters',
            {
              'recipient_identity_key_id': recipientIdentityKeyId,
              'sender_key_id': sender.senderKeyId,
              'message_counter': counter,
              'conversation_id': sender.senderKeyId,
              'envelope_id':
                  'portable-backup:$recipientIdentityKeyId:${sender.senderKeyId}:$counter',
              'first_seen_at_unix_ms': firstSeenAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          batchCount += 1;
          if (batchCount == 1000) {
            await batch.commit(noResult: true);
            batch = db.batch();
            batchCount = 0;
          }
          if (counter == range.end) break;
        }
      }
    }
    if (batchCount > 0) await batch.commit(noResult: true);
  }

  // --- Clean Store ---

  Future<void> clearAll() async {
    final db = _getDb();
    await db.transaction((txn) async {
      final counterMetadata = await _readMetadata(txn, const {
        'counter_namespace',
        'counter_retired_namespaces',
      });
      final retired = _parseRetiredCounterNamespaces(
        counterMetadata['counter_retired_namespaces'],
      );
      final activeNamespace =
          int.tryParse(counterMetadata['counter_namespace'] ?? '') ?? 0;
      if (activeNamespace > 0 &&
          activeNamespace <= androidMessageCounterNamespaceMask) {
        retired.add(activeNamespace);
      }
      await txn.delete('contacts');
      await txn.delete('messages');
      await txn.delete('pending_envelopes');
      await txn.delete('relay_ha_outbox');
      await txn.delete('relay_ha_result_outbox');
      await txn.delete('relay_ha_file_parts');
      await txn.delete('mailbox_quarantine');
      await txn.delete('deferred_mailbox_envelopes');
      await txn.delete('file_transfer_chunks');
      await txn.delete('file_transfers');
      await txn.delete('sealed_envelopes');
      await txn.delete('group_events');
      await txn.delete('group_members');
      await txn.delete('groups');
      await txn.delete('metadata');
      if (retired.isNotEmpty) {
        await _writeMetadata(
          txn,
          'counter_retired_namespaces',
          jsonEncode(retired.toList()..sort()),
        );
      }
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
            (message.isOutgoing &&
                        message.deliveryStatus == AndroidDeliveryStatus.sent
                    ? message.copyWith(
                        deliveryStatus: AndroidDeliveryStatus.legacySent,
                      )
                    : message)
                .toJson(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await _backfillReceivedMessageCounters(txn);
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

class AndroidPendingEnvelopeRecord {
  const AndroidPendingEnvelopeRecord({
    required this.envelopeId,
    required this.logicalMessageId,
    this.logicalKind = AndroidPendingEnvelopeKind.message,
    required this.recipientKeyId,
    required this.recipientDisplayName,
    required this.recipientContactJson,
    required this.envelopeBase64,
    required this.createdAtUnixMs,
    required this.childIndex,
    required this.childCount,
    this.attemptCount = 0,
    this.nextAttemptAtUnixMs,
    this.lastError,
    this.deliveryStatus = AndroidDeliveryStatus.pending,
    this.lastRoute,
  });

  factory AndroidPendingEnvelopeRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidPendingEnvelopeRecord(
      envelopeId: json['envelope_id']?.toString() ?? '',
      logicalMessageId: json['logical_message_id']?.toString() ?? '',
      logicalKind:
          json['logical_kind']?.toString() ??
          AndroidPendingEnvelopeKind.message,
      recipientKeyId: json['recipient_key_id']?.toString() ?? '',
      recipientDisplayName: json['recipient_display_name']?.toString() ?? '',
      recipientContactJson: json['recipient_contact_json']?.toString() ?? '',
      envelopeBase64: json['envelope_b64']?.toString() ?? '',
      createdAtUnixMs: (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      childIndex: (json['child_index'] as num?)?.toInt() ?? 0,
      childCount: (json['child_count'] as num?)?.toInt() ?? 1,
      attemptCount: (json['attempt_count'] as num?)?.toInt() ?? 0,
      nextAttemptAtUnixMs: (json['next_attempt_at_unix_ms'] as num?)?.toInt(),
      lastError: json['last_error']?.toString(),
      deliveryStatus:
          json['delivery_status']?.toString() ?? AndroidDeliveryStatus.pending,
      lastRoute: json['last_route']?.toString(),
    );
  }

  final String envelopeId;
  final String logicalMessageId;
  final String logicalKind;
  final String recipientKeyId;
  final String recipientDisplayName;
  final String recipientContactJson;
  final String envelopeBase64;
  final int createdAtUnixMs;
  final int childIndex;
  final int childCount;
  final int attemptCount;
  final int? nextAttemptAtUnixMs;
  final String? lastError;
  final String deliveryStatus;
  final String? lastRoute;

  AndroidContactRecord toContactRecord() => AndroidContactRecord(
    keyId: recipientKeyId,
    displayName: recipientDisplayName,
    contactJson: recipientContactJson,
  );

  Map<String, Object?> toJson() => {
    'envelope_id': envelopeId,
    'logical_message_id': logicalMessageId,
    'logical_kind': logicalKind,
    'recipient_key_id': recipientKeyId,
    'recipient_display_name': recipientDisplayName,
    'recipient_contact_json': recipientContactJson,
    'envelope_b64': envelopeBase64,
    'created_at_unix_ms': createdAtUnixMs,
    'child_index': childIndex,
    'child_count': childCount,
    'attempt_count': attemptCount,
    'next_attempt_at_unix_ms': nextAttemptAtUnixMs,
    'last_error': lastError,
    'delivery_status': deliveryStatus,
    'last_route': lastRoute,
  };
}

abstract final class AndroidPendingEnvelopeKind {
  static const message = 'message';
  static const groupControl = 'group_control';
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
