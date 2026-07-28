# -*- coding: utf-8 -*-
import json
import os
import time
import base64
import traceback
from urllib.parse import parse_qs

# 尝试导入 tablestore SDK
try:
    from tablestore import (
        OTSClient,
        RowExistenceExpectation,
        Condition,
        Direction,
        Row,
        INF_MIN,
        INF_MAX
    )
    HAS_TABLESTORE = True
    TABLESTORE_IMPORT_ERROR = None
except Exception as e:
    HAS_TABLESTORE = False
    TABLESTORE_IMPORT_ERROR = str(e)

# 批量写入接口在部分旧版 SDK 中缺失，单独探测并保留逐行写入兜底
try:
    from tablestore import (
        BatchWriteRowRequest,
        TableInBatchWriteRowItem,
        PutRowItem,
        DeleteRowItem
    )
    HAS_BATCH_WRITE = True
except Exception:
    HAS_BATCH_WRITE = False

TABLE_CONVERSATIONS = 'conversations'
TABLE_MESSAGES = 'messages'
# 墓碑表。主键 (entity_type, entity_id)，entity_type 取 'conversation' | 'message'
TABLE_DELETIONS = 'deletions'
TABLE_SENSOR_READINGS = 'sensor_readings'
TABLE_COMMANDS = 'commands'

ENTITY_CONVERSATION = 'conversation'
ENTITY_MESSAGE = 'message'

# Tablestore 单次 BatchWriteRow 最多 200 行
BATCH_WRITE_LIMIT = 200
# 单次 GetRange 的页大小；配合 next_start_primary_key 翻页，不做总量截断
RANGE_PAGE_SIZE = 500


def get_ots_client():
    endpoint = os.environ.get('OTS_ENDPOINT', '').strip()
    access_key_id = os.environ.get('OTS_AK', '').strip()
    access_key_secret = os.environ.get('OTS_SK', '').strip()
    instance_name = os.environ.get('OTS_INSTANCE', '').strip()

    missing = []
    if not endpoint: missing.append('OTS_ENDPOINT')
    if not access_key_id: missing.append('OTS_AK')
    if not access_key_secret: missing.append('OTS_SK')
    if not instance_name: missing.append('OTS_INSTANCE')

    if missing:
        raise ValueError(f"FC 环境变量缺失: {', '.join(missing)}。请在 FC 控制台【配置 -> 环境变量】中填写。")

    return OTSClient(endpoint, access_key_id, access_key_secret, instance_name)


def extract_attrs(row):
    """
    安全解析 Tablestore 属性列（兼容 2 元组和 3 元组 (name, value, timestamp)）
    """
    attrs = {}
    if hasattr(row, 'attribute_columns') and row.attribute_columns:
        for col in row.attribute_columns:
            if isinstance(col, (list, tuple)) and len(col) >= 2:
                attrs[col[0]] = col[1]
    return attrs


def as_int(value, default=0):
    """把 JSON 里可能出现的 None / 字符串 / 浮点时间戳统一成毫秒整数"""
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default


def as_text(value, default=''):
    if value is None:
        return default
    if isinstance(value, str):
        return value
    return str(value)


def canonical_id(value):
    """
    会话/消息 ID 的规范形式：去空白 + 转小写。

    iOS 的 `UUID.uuidString` 恒为大写，浏览器的 `crypto.randomUUID()` 恒为小写，
    而 Tablestore 主键按字节比较。同一条记录因此会以大小写两种形式各存一行，
    墓碑也永远匹配不上对方那一行——这正是"删了又活过来"的根因。
    云端是唯一的仲裁方，统一在这里折叠成小写。
    """
    return as_text(value).strip().lower()


# Tablestore 对"表不存在"在不同接口上给出不同的错误码和文案：
# GetRange 报 OTSParameterInvalid / "Request table not exist"，
# 其它接口报 OTSObjectNotExist / "Requested table does not exist"。
# 只认一种写法会让降级逻辑失效，直接把原始 traceback 甩给客户端。
_TABLE_MISSING_MARKERS = (
    'otsobjectnotexist',
    'table not exist',
    'table does not exist',
    'does not exist',
)


def is_table_missing(error):
    text = str(error).lower()
    return any(marker in text for marker in _TABLE_MISSING_MARKERS)


# 建表提示用：每张表的主键定义，缺表时原样告诉用户该怎么建
TABLE_PRIMARY_KEYS = {
    TABLE_CONVERSATIONS: 'conversation_id(字符串)',
    TABLE_MESSAGES: 'conversation_id(字符串)、message_id(字符串)',
    TABLE_DELETIONS: 'entity_type(字符串)、entity_id(字符串)',
    TABLE_SENSOR_READINGS: 'device_id(字符串)、sequence(整数)',
    TABLE_COMMANDS: 'command_id(字符串)',
}


def missing_tables_hint(table_names):
    if not table_names:
        return None
    parts = [
        f"'{name}'(主键依次为 {TABLE_PRIMARY_KEYS.get(name, '见文档')})"
        for name in sorted(table_names)
    ]
    return (
        "以下 Tablestore 数据表不存在，相关数据无法同步："
        + "，".join(parts)
        + "。请在 Tablestore 控制台按上述主键新建这些表。"
    )


def fetch_rows(client, table_name, start_pk, end_pk, missing_tables):
    """
    读取整张表；表不存在时记录下来并返回空列表，让同步降级而不是整体 500。
    """
    try:
        return list(iter_range(client, table_name, start_pk, end_pk))
    except Exception as error:
        if is_table_missing(error):
            missing_tables.add(table_name)
            return []
        raise


def iter_range(client, table_name, start_pk, end_pk):
    """
    翻页遍历整张表。原实现用固定 limit 截断，会静默丢掉超出部分的数据。
    """
    next_start_pk = start_pk
    while next_start_pk is not None:
        _, next_start_pk, rows, _ = client.get_range(
            table_name,
            Direction.FORWARD,
            next_start_pk,
            end_pk,
            columns_to_get=[],
            limit=RANGE_PAGE_SIZE
        )
        for row in rows or []:
            yield row


def write_rows(client, table_name, items):
    """
    items: [(primary_key, attribute_columns_or_None)]
    attribute_columns 为 None 表示删除该行。优先批量写入，SDK 不支持时逐行兜底。
    """
    if not items:
        return

    ignore = Condition(RowExistenceExpectation.IGNORE)

    if not HAS_BATCH_WRITE:
        for primary_key, attrs in items:
            if attrs is None:
                client.delete_row(table_name, Row(primary_key), ignore)
            else:
                client.put_row(table_name, Row(primary_key, attrs), ignore)
        return

    for offset in range(0, len(items), BATCH_WRITE_LIMIT):
        chunk = items[offset:offset + BATCH_WRITE_LIMIT]
        request = BatchWriteRowRequest()
        batch_items = []
        for primary_key, attrs in chunk:
            if attrs is None:
                batch_items.append(DeleteRowItem(Row(primary_key), ignore))
            else:
                batch_items.append(PutRowItem(Row(primary_key, attrs), ignore))
        request.add(TableInBatchWriteRowItem(table_name, batch_items))
        client.batch_write_row(request)


def load_tombstones(client):
    """
    读取全部墓碑。返回 (conversation_ids, message_ids, records, supported)。
    墓碑表尚未创建时降级为空集合，让老部署仍能收发消息。
    """
    conv_ids = set()
    msg_ids = set()
    records = []
    try:
        rows = iter_range(
            client,
            TABLE_DELETIONS,
            [('entity_type', INF_MIN), ('entity_id', INF_MIN)],
            [('entity_type', INF_MAX), ('entity_id', INF_MAX)]
        )
        seen = set()
        for row in rows:
            entity_type = as_text(row.primary_key[0][1]).strip()
            entity_id = canonical_id(row.primary_key[1][1])
            if not entity_id:
                continue
            attrs = extract_attrs(row)
            # 老部署里同一条删除可能留下大小写两行墓碑，对客户端只报一条。
            if (entity_type, entity_id) not in seen:
                seen.add((entity_type, entity_id))
                records.append({
                    'type': entity_type,
                    'id': entity_id,
                    'conversationId': canonical_id(attrs.get('conversation_id')) or None,
                    'deletedAt': as_int(attrs.get('deleted_at'))
                })
            if entity_type == ENTITY_CONVERSATION:
                conv_ids.add(entity_id)
            elif entity_type == ENTITY_MESSAGE:
                msg_ids.add(entity_id)
    except Exception as error:
        if is_table_missing(error):
            return set(), set(), [], False
        raise
    return conv_ids, msg_ids, records, True


def purge_deleted_rows(client, conv_ids, msg_ids):
    """
    按规范 ID 清除被墓碑标记的会话行与消息行（含级联删除会话名下的消息）。

    整表扫描而不是按主键区间定点删除：历史数据里同一条记录可能以大小写两种
    形式各存一行，主键区间只能命中其中一种。而消息墓碑经常拿不到
    conversationId（旧客户端不带），定点删除同样无从下手。单用户量级下整表
    扫一遍换来"任何写法都能删掉"，这个代价值得。
    """
    if not conv_ids and not msg_ids:
        return

    if conv_ids:
        victims = []
        try:
            for row in iter_range(
                client,
                TABLE_CONVERSATIONS,
                [('conversation_id', INF_MIN)],
                [('conversation_id', INF_MAX)]
            ):
                stored_id = row.primary_key[0][1]
                if canonical_id(stored_id) in conv_ids:
                    victims.append(([('conversation_id', stored_id)], None))
        except Exception as error:
            if not is_table_missing(error):
                raise
        write_rows(client, TABLE_CONVERSATIONS, victims)

    victims = []
    try:
        for row in iter_range(
            client,
            TABLE_MESSAGES,
            [('conversation_id', INF_MIN), ('message_id', INF_MIN)],
            [('conversation_id', INF_MAX), ('message_id', INF_MAX)]
        ):
            stored_conv = row.primary_key[0][1]
            stored_msg = row.primary_key[1][1]
            if canonical_id(stored_conv) in conv_ids or canonical_id(stored_msg) in msg_ids:
                victims.append((
                    [('conversation_id', stored_conv), ('message_id', stored_msg)],
                    None
                ))
    except Exception as error:
        if not is_table_missing(error):
            raise
    write_rows(client, TABLE_MESSAGES, victims)


def purge_case_variants(client, conv_ids, msg_ids):
    """
    删掉与刚写入的规范行指向同一条记录、但主键大小写不同的历史遗留行。

    在规范化之前，iOS 与 Web 各自写入了大写/小写两行"孪生"记录。规范化只保证
    此后不再产生新的孪生行，已有的那一半仍会被拉取成一条独立记录——统计里那些
    虚高的条数就是它们。这里在写入规范行之后顺手清掉对应的另一种写法。
    """
    if conv_ids:
        victims = []
        try:
            for row in iter_range(
                client,
                TABLE_CONVERSATIONS,
                [('conversation_id', INF_MIN)],
                [('conversation_id', INF_MAX)]
            ):
                stored = row.primary_key[0][1]
                if stored != canonical_id(stored) and canonical_id(stored) in conv_ids:
                    victims.append(([('conversation_id', stored)], None))
        except Exception as error:
            if not is_table_missing(error):
                raise
        write_rows(client, TABLE_CONVERSATIONS, victims)

    if not conv_ids and not msg_ids:
        return
    victims = []
    try:
        for row in iter_range(
            client,
            TABLE_MESSAGES,
            [('conversation_id', INF_MIN), ('message_id', INF_MIN)],
            [('conversation_id', INF_MAX), ('message_id', INF_MAX)]
        ):
            stored_conv = row.primary_key[0][1]
            stored_msg = row.primary_key[1][1]
            if stored_conv == canonical_id(stored_conv) and stored_msg == canonical_id(stored_msg):
                continue
            if canonical_id(stored_conv) in conv_ids or canonical_id(stored_msg) in msg_ids:
                victims.append((
                    [('conversation_id', stored_conv), ('message_id', stored_msg)],
                    None
                ))
    except Exception as error:
        if not is_table_missing(error):
            raise
    write_rows(client, TABLE_MESSAGES, victims)


def get_cors_headers():
    return {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS, DELETE',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400'
    }


def handle_push(client, body_data):
    conversations = body_data.get('conversations') or []
    messages = body_data.get('messages') or []
    deletions = body_data.get('deletions') or []

    now_ms = int(time.time() * 1000)
    missing_tables = set()

    # 1. 先落墓碑：删除意图优先于内容写入，避免同一批里"删了又被写回"
    tombstone_rows = []
    accepted_deletions = 0
    pushed_conv_tombstones = set()
    pushed_msg_tombstones = set()

    for item in deletions:
        if not isinstance(item, dict):
            continue
        entity_type = as_text(item.get('type')).strip()
        entity_id = canonical_id(item.get('id'))
        if entity_type not in (ENTITY_CONVERSATION, ENTITY_MESSAGE) or not entity_id:
            continue
        deleted_at = as_int(item.get('deletedAt') or item.get('deleted_at'), now_ms)
        conversation_id = canonical_id(item.get('conversationId') or item.get('conversation_id'))
        tombstone_rows.append((
            [('entity_type', entity_type), ('entity_id', entity_id)],
            [
                ('conversation_id', conversation_id),
                ('deleted_at', deleted_at)
            ]
        ))
        accepted_deletions += 1
        if entity_type == ENTITY_CONVERSATION:
            pushed_conv_tombstones.add(entity_id)
        else:
            pushed_msg_tombstones.add(entity_id)

    deletions_supported = True
    if tombstone_rows:
        try:
            write_rows(client, TABLE_DELETIONS, tombstone_rows)
        except Exception as error:
            if is_table_missing(error):
                deletions_supported = False
                missing_tables.add(TABLE_DELETIONS)
                accepted_deletions = 0
                pushed_conv_tombstones = set()
                pushed_msg_tombstones = set()
            else:
                raise

    if deletions_supported:
        try:
            purge_deleted_rows(client, pushed_conv_tombstones, pushed_msg_tombstones)
        except Exception as error:
            # 内容表还没建时没有行可删，墓碑已经落库，删除意图不会丢。
            if not is_table_missing(error):
                raise

    # 2. 读出全量墓碑，过滤掉针对已删除对象的写入。
    #    客户端正常是 pull-then-push，本地已应用远端删除；这里再兜一层，
    #    保证任何顺序下都不会有旧客户端把已删记录复活。
    known_conv_tombstones, known_msg_tombstones, _, table_present = load_tombstones(client)
    if not table_present:
        deletions_supported = False
        missing_tables.add(TABLE_DELETIONS)

    conv_rows = []
    skipped_conversations = 0
    for conv in conversations:
        if not isinstance(conv, dict):
            continue
        conv_id = canonical_id(conv.get('id'))
        if not conv_id:
            continue
        if conv_id in known_conv_tombstones:
            skipped_conversations += 1
            continue
        conv_rows.append((
            [('conversation_id', conv_id)],
            [
                ('title', as_text(conv.get('title'), '未命名对话')),
                ('kind', as_text(conv.get('kind'), 'text')),
                ('device_id', as_text(conv.get('deviceId'))),
                ('created_at', as_int(conv.get('createdAt'), now_ms)),
                ('updated_at', as_int(conv.get('updatedAt'), now_ms))
            ]
        ))

    msg_rows = []
    skipped_messages = 0
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        conv_id = canonical_id(msg.get('conversation_id') or msg.get('conversationId'))
        msg_id = canonical_id(msg.get('id'))
        if not conv_id or not msg_id:
            continue
        if conv_id in known_conv_tombstones or msg_id in known_msg_tombstones:
            skipped_messages += 1
            continue
        content = msg.get('text')
        if content is None:
            content = msg.get('content')
        msg_rows.append((
            [('conversation_id', conv_id), ('message_id', msg_id)],
            [
                ('role', as_text(msg.get('role'), 'user')),
                ('content', as_text(content)),
                ('created_at', as_int(msg.get('createdAt'), now_ms)),
                ('tool_invocations', json.dumps(msg.get('toolInvocations') or [], ensure_ascii=False))
            ]
        ))

    sensor_readings = body_data.get('sensorReadings') or body_data.get('sensor_readings') or []
    sr_rows = []
    for item in sensor_readings:
        if not isinstance(item, dict):
            continue
        device_id = as_text(item.get('deviceId') or item.get('device_id')).strip()
        # as_int 永远有默认值，不能用它判断"缺字段"：否则没有 sequence 的读数
        # 会全部落到 sequence=0 这一行上，互相覆盖。
        sequence = as_int(item.get('sequence'), None)
        if not device_id or sequence is None:
            continue
        recorded_at = as_int(item.get('recordedAt') or item.get('recorded_at'), now_ms)
        received_at = as_int(item.get('receivedAt') or item.get('received_at'), recorded_at)
        timestamp_est = bool(item.get('timestampEstimated') or item.get('timestamp_estimated') or False)
        soil_raw = as_int(item.get('soilRaw') or item.get('soil_raw'), 0)
        temp = item.get('temperature')
        hum = item.get('humidity')
        light = item.get('lightLux') if item.get('lightLux') is not None else item.get('light_lux')
        
        attrs = [
            ('recorded_at', recorded_at),
            ('received_at', received_at),
            ('timestamp_estimated', timestamp_est),
            ('soil_raw', soil_raw)
        ]
        if temp is not None: attrs.append(('temperature', float(temp)))
        if hum is not None: attrs.append(('humidity', float(hum)))
        if light is not None: attrs.append(('light_lux', float(light)))

        sr_rows.append(([('device_id', device_id), ('sequence', sequence)], attrs))

    written = {}
    for table_name, rows in (
        (TABLE_SENSOR_READINGS, sr_rows),
        (TABLE_CONVERSATIONS, conv_rows),
        (TABLE_MESSAGES, msg_rows),
    ):
        if not rows:
            written[table_name] = 0
            continue
        try:
            write_rows(client, table_name, rows)
            written[table_name] = len(rows)
        except Exception as error:
            if not is_table_missing(error):
                raise
            # 缺表时这批数据没写进去，计数必须如实反映，不能报成已上传。
            missing_tables.add(table_name)
            written[table_name] = 0

    # 规范行已经落库，把同一条记录的大小写孪生行清掉，避免拉取时重复成两条。
    if TABLE_CONVERSATIONS not in missing_tables and TABLE_MESSAGES not in missing_tables:
        try:
            purge_case_variants(
                client,
                {pk[0][1] for pk, _ in conv_rows},
                {pk[1][1] for pk, _ in msg_rows}
            )
        except Exception as error:
            if not is_table_missing(error):
                raise

    result = {
        'success': True,
        'conversations_count': written[TABLE_CONVERSATIONS],
        'messages_count': written[TABLE_MESSAGES],
        'sensor_readings_count': written[TABLE_SENSOR_READINGS],
        'deletions_count': accepted_deletions,
        'skipped_conversations': skipped_conversations,
        'skipped_messages': skipped_messages,
        'serverTime': int(time.time() * 1000)
    }
    hint = missing_tables_hint(missing_tables)
    if hint:
        result['missing_tables'] = sorted(missing_tables)
        result['deletions_supported'] = deletions_supported
        result['deletions_hint'] = hint
    return result


def handle_pull(client, query_params):
    since = as_int(query_params.get('since'), 0)
    missing_tables = set()

    conv_tombstones, msg_tombstones, deletion_records, deletions_supported = load_tombstones(client)
    if not deletions_supported:
        missing_tables.add(TABLE_DELETIONS)

    # 尚未被 push 清理掉的大小写孪生行在这里合并成一条，取 updated_at 更新的那份。
    conv_by_id = {}
    for row in fetch_rows(
        client,
        TABLE_CONVERSATIONS,
        [('conversation_id', INF_MIN)],
        [('conversation_id', INF_MAX)],
        missing_tables
    ):
        conv_id = canonical_id(row.primary_key[0][1])
        if not conv_id or conv_id in conv_tombstones:
            continue
        attrs = extract_attrs(row)
        updated_at = as_int(attrs.get('updated_at'))
        if updated_at < since:
            continue
        previous = conv_by_id.get(conv_id)
        if previous and previous['updatedAt'] >= updated_at:
            continue
        conv_by_id[conv_id] = {
            'id': conv_id,
            'title': as_text(attrs.get('title')),
            'kind': as_text(attrs.get('kind'), 'text'),
            'deviceId': attrs.get('device_id') or None,
            'createdAt': as_int(attrs.get('created_at')),
            'updatedAt': updated_at
        }
    conversations_res = list(conv_by_id.values())

    msg_by_id = {}
    for row in fetch_rows(
        client,
        TABLE_MESSAGES,
        [('conversation_id', INF_MIN), ('message_id', INF_MIN)],
        [('conversation_id', INF_MAX), ('message_id', INF_MAX)],
        missing_tables
    ):
        conv_id = canonical_id(row.primary_key[0][1])
        msg_id = canonical_id(row.primary_key[1][1])
        if not conv_id or not msg_id:
            continue
        if conv_id in conv_tombstones or msg_id in msg_tombstones:
            continue
        attrs = extract_attrs(row)
        created_at = as_int(attrs.get('created_at'))
        if created_at < since:
            continue
        # 消息按 message_id 去重即可：孪生行内容一致，保留先读到的那条。
        if msg_id in msg_by_id:
            continue
        try:
            tool_invs = json.loads(attrs.get('tool_invocations') or '[]')
        except Exception:
            tool_invs = []
        content = as_text(attrs.get('content'))
        msg_by_id[msg_id] = {
            'id': msg_id,
            'conversation_id': conv_id,
            'role': as_text(attrs.get('role'), 'user'),
            'text': content,
            'content': content,
            'createdAt': created_at,
            'toolInvocations': tool_invs
        }
    messages_res = list(msg_by_id.values())

    # 墓碑始终整表返回：它是"删除事实"的唯一载体，漏掉一条就意味着某端复活记录。
    # 单用户量级很小；日后需要收敛可在此按 since 过滤并配合各端保留期清理。
    sensor_readings_res = []
    for row in fetch_rows(
        client,
        TABLE_SENSOR_READINGS,
        [('device_id', INF_MIN), ('sequence', INF_MIN)],
        [('device_id', INF_MAX), ('sequence', INF_MAX)],
        missing_tables
    ):
        device_id = row.primary_key[0][1]
        seq = as_int(row.primary_key[1][1])
        attrs = extract_attrs(row)
        recorded_at = as_int(attrs.get('recorded_at'))
        if recorded_at >= since:
            sensor_readings_res.append({
                'deviceId': device_id,
                'sequence': seq,
                'recordedAt': recorded_at,
                'receivedAt': as_int(attrs.get('received_at'), recorded_at),
                'timestampEstimated': bool(attrs.get('timestamp_estimated', False)),
                'soilRaw': as_int(attrs.get('soil_raw')),
                'temperature': attrs.get('temperature'),
                'humidity': attrs.get('humidity'),
                'lightLux': attrs.get('light_lux')
            })

    result = {
        'success': True,
        'conversations': conversations_res,
        'messages': messages_res,
        'sensorReadings': sensor_readings_res,
        'sensor_readings': sensor_readings_res,
        'deletions': deletion_records,
        'serverTime': int(time.time() * 1000)
    }
    hint = missing_tables_hint(missing_tables)
    if hint:
        # 缺表是配置问题，不该表现为 500：其余表照常同步，同时把建表指引带回去。
        result['missing_tables'] = sorted(missing_tables)
        result['deletions_supported'] = deletions_supported
        result['deletions_hint'] = hint
    return result


def handle_create_command(client, body_data):
    device_id = as_text(body_data.get('deviceId') or body_data.get('device_id') or 'default_device').strip()
    action = as_text(body_data.get('action') or 'refresh_sensor').strip()
    now_ms = int(time.time() * 1000)
    command_id = f"cmd_{now_ms}_{int(time.time() * 1000) % 1000}"

    row = (
        [('command_id', command_id)],
        [
            ('device_id', device_id),
            ('action', action),
            ('status', 'pending'),
            ('created_at', now_ms),
            ('result_reading', '')
        ]
    )
    try:
        write_rows(client, TABLE_COMMANDS, [row])
    except Exception as error:
        if is_table_missing(error):
            return {'success': False, 'error': f"表 '{TABLE_COMMANDS}' 不存在，请在 Tablestore 控制台创建。"}
        raise

    return {
        'success': True,
        'commandId': command_id,
        'command_id': command_id,
        'status': 'pending',
        'createdAt': now_ms
    }


def handle_poll_command(client, query_params):
    device_id = as_text(query_params.get('deviceId') or query_params.get('device_id') or 'default_device').strip()
    try:
        for row in iter_range(
            client,
            TABLE_COMMANDS,
            [('command_id', INF_MIN)],
            [('command_id', INF_MAX)]
        ):
            cmd_id = row.primary_key[0][1]
            attrs = extract_attrs(row)
            if attrs.get('status') == 'pending':
                target_dev = as_text(attrs.get('device_id'))
                if not target_dev or target_dev == device_id or device_id == 'default_device':
                    return {
                        'success': True,
                        'hasCommand': True,
                        'commandId': cmd_id,
                        'command_id': cmd_id,
                        'action': as_text(attrs.get('action'), 'refresh_sensor')
                    }
    except Exception as error:
        if is_table_missing(error):
            return {'success': True, 'hasCommand': False}
        raise

    return {'success': True, 'hasCommand': False}


def handle_respond_command(client, body_data):
    command_id = as_text(body_data.get('commandId') or body_data.get('command_id')).strip()
    if not command_id:
        return {'success': False, 'error': '缺失 commandId'}
    
    now_ms = int(time.time() * 1000)
    reading = body_data.get('reading') or body_data.get('sensorReading') or {}
    reading_json = json.dumps(reading)

    row = (
        [('command_id', command_id)],
        [
            ('status', 'completed'),
            ('updated_at', now_ms),
            ('result_reading', reading_json)
        ]
    )
    try:
        write_rows(client, TABLE_COMMANDS, [row])
    except Exception as error:
        if not is_table_missing(error):
            raise

    if isinstance(reading, dict) and reading:
        try:
            device_id = as_text(reading.get('deviceId') or reading.get('device_id') or 'default_device')
            seq = as_int(reading.get('sequence'), now_ms // 1000)
            rec_at = as_int(reading.get('recordedAt') or reading.get('recorded_at'), now_ms)
            soil = as_int(reading.get('soilRaw') or reading.get('soil_raw'), 0)
            temp = reading.get('temperature')
            hum = reading.get('humidity')
            light = reading.get('lightLux') if reading.get('lightLux') is not None else reading.get('light_lux')
            
            attrs = [
                ('recorded_at', rec_at),
                ('received_at', now_ms),
                ('timestamp_estimated', False),
                ('soil_raw', soil)
            ]
            if temp is not None: attrs.append(('temperature', float(temp)))
            if hum is not None: attrs.append(('humidity', float(hum)))
            if light is not None: attrs.append(('light_lux', float(light)))
            
            write_rows(client, TABLE_SENSOR_READINGS, [([('device_id', device_id), ('sequence', seq)], attrs)])
        except Exception:
            pass

    return {'success': True, 'commandId': command_id, 'status': 'completed'}


def handle_get_command_status(client, query_params):
    command_id = as_text(query_params.get('commandId') or query_params.get('command_id')).strip()
    if not command_id:
        return {'success': False, 'error': '缺失 commandId'}

    try:
        rows = list(iter_range(
            client,
            TABLE_COMMANDS,
            [('command_id', command_id)],
            [('command_id', command_id)]
        ))
        if rows:
            attrs = extract_attrs(rows[0])
            status = as_text(attrs.get('status'), 'pending')
            result_json = as_text(attrs.get('result_reading'))
            reading = json.loads(result_json) if result_json else None
            return {
                'success': True,
                'commandId': command_id,
                'status': status,
                'reading': reading
            }
    except Exception as error:
        if not is_table_missing(error):
            raise

    return {'success': False, 'error': '未找到对应指令', 'status': 'not_found'}


def main_logic(method, path, headers, query_params, body_data):
    """
    核心业务逻辑
    """
    cors_headers = get_cors_headers()

    if method == 'OPTIONS':
        return 204, cors_headers, ''

    if not HAS_TABLESTORE:
        return 500, cors_headers, {
            'error': f"缺失 Python tablestore 依赖包: {TABLESTORE_IMPORT_ERROR}",
            'solution': "请在 FC 3.0 控制台【代码】页面的下方终端 (Terminal) 中运行命令: pip install tablestore -t . 部署后重试。"
        }

    # 校验 Token。注意：未配置 AUTH_TOKEN 时接口对公网完全开放，
    # 务必在 FC 环境变量里设置 AUTH_TOKEN。
    auth_token = headers.get('x-auth-token') or headers.get('X-Auth-Token') or ''
    expected_token = os.environ.get('AUTH_TOKEN', '').strip()
    if expected_token and auth_token != expected_token:
        return 401, cors_headers, {'error': 'Unauthorized: 无效的 x-auth-token'}

    client = get_ots_client()

    clean_path = path.rstrip('/')

    if method == 'POST':
        if clean_path in ('/command/create', '/commands/create') or body_data.get('action') == 'create_command':
            return 200, cors_headers, handle_create_command(client, body_data)
        if clean_path in ('/command/respond', '/commands/respond') or 'commandId' in body_data and 'reading' in body_data:
            return 200, cors_headers, handle_respond_command(client, body_data)

        is_push = (
            clean_path in ('/sync/push', '/messages', '/push', '', '/') or
            'conversations' in body_data or
            'messages' in body_data or
            'deletions' in body_data or
            'sensorReadings' in body_data or
            'sensor_readings' in body_data
        )
        if is_push:
            return 200, cors_headers, handle_push(client, body_data)

    if method == 'GET':
        if clean_path in ('/command/poll', '/commands/poll'):
            return 200, cors_headers, handle_poll_command(client, query_params)
        if clean_path in ('/command/status', '/commands/status') or ('commandId' in query_params or 'command_id' in query_params):
            return 200, cors_headers, handle_get_command_status(client, query_params)

        is_pull = (
            clean_path in ('/sync/pull', '/messages', '/pull', '', '/') or
            'since' in query_params
        )
        if is_pull:
            return 200, cors_headers, handle_pull(client, query_params)

    return 404, cors_headers, {'error': f'未知的路由: {method} {path}'}


def handler(*args, **kwargs):
    """
    兼容 FC 3.0 事件函数 (event, context) 与 WSGI 函数 (environ, start_response)
    """
    cors_headers = get_cors_headers()
    try:
        if len(args) == 2 and callable(args[1]):
            environ, start_response = args[0], args[1]
            method = environ.get('REQUEST_METHOD', 'GET').upper()
            path = environ.get('PATH_INFO', '/')
            query_string = environ.get('QUERY_STRING', '')
            parsed_query = parse_qs(query_string)
            query_params = {k: v[0] for k, v in parsed_query.items()}

            headers = {}
            for k, v in environ.items():
                if k.startswith('HTTP_'):
                    headers[k[5:].replace('_', '-').lower()] = v
                elif k in ('CONTENT_TYPE', 'CONTENT_LENGTH'):
                    headers[k.replace('_', '-').lower()] = v

            body_data = {}
            if method in ('POST', 'PUT'):
                try:
                    length = int(environ.get('CONTENT_LENGTH', 0))
                    if length > 0:
                        body_data = json.loads(environ['wsgi.input'].read(length).decode('utf-8'))
                except Exception: pass

            status_code, resp_headers, resp_data = main_logic(method, path, headers, query_params, body_data)

            status_str = "200 OK" if status_code == 200 else f"{status_code} Error"
            header_list = [(k, v) for k, v in resp_headers.items()]
            start_response(status_str, header_list)

            body_bytes = resp_data.encode('utf-8') if isinstance(resp_data, str) else json.dumps(resp_data, ensure_ascii=False).encode('utf-8')
            return [body_bytes]

        event, context = args[0], args[1]
        if isinstance(event, (bytes, bytearray)):
            event = event.decode('utf-8')
        if isinstance(event, str):
            try: event_dict = json.loads(event)
            except Exception: event_dict = {}
        else:
            event_dict = event if isinstance(event, dict) else {}

        headers = {k.lower(): v for k, v in (event_dict.get('headers') or {}).items()}
        method = (event_dict.get('httpMethod') or event_dict.get('requestContext', {}).get('http', {}).get('method') or 'GET').upper()

        candidate_paths = [
            event_dict.get('rawPath'),
            event_dict.get('path'),
            event_dict.get('requestContext', {}).get('http', {}).get('path'),
            event_dict.get('requestContext', {}).get('path'),
            headers.get('x-forwarded-path'),
            headers.get('x-fc-path')
        ]
        path = next((p for p in candidate_paths if p and p != '/'), '/')

        query_params = event_dict.get('queryParameters') or event_dict.get('queryStringParameters') or {}

        raw_body = event_dict.get('body', '')
        if event_dict.get('isBase64Encoded', False) and raw_body:
            raw_body = base64.b64decode(raw_body).decode('utf-8')

        body_data = {}
        if raw_body and method in ('POST', 'PUT'):
            try:
                body_data = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
            except Exception: pass

        status_code, resp_headers, resp_data = main_logic(method, path, headers, query_params, body_data)

        body_str = resp_data if isinstance(resp_data, str) else json.dumps(resp_data, ensure_ascii=False)
        return {
            'isBase64Encoded': False,
            'statusCode': status_code,
            'headers': resp_headers,
            'body': body_str
        }

    except Exception as e:
        err_body = json.dumps({'error': f'系统未捕获异常: {str(e)}', 'traceback': traceback.format_exc()}, ensure_ascii=False)
        if len(args) == 2 and callable(args[1]):
            args[1]('500 Internal Server Error', [('Content-Type', 'application/json; charset=utf-8')])
            return [err_body.encode('utf-8')]
        return {
            'isBase64Encoded': False,
            'statusCode': 500,
            'headers': cors_headers,
            'body': err_body
        }
