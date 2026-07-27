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


def is_table_missing(error):
    text = str(error)
    return 'OTSObjectNotExist' in text or 'does not exist' in text


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
        for row in rows:
            entity_type = row.primary_key[0][1]
            entity_id = row.primary_key[1][1]
            attrs = extract_attrs(row)
            record = {
                'type': entity_type,
                'id': entity_id,
                'conversationId': attrs.get('conversation_id') or None,
                'deletedAt': as_int(attrs.get('deleted_at'))
            }
            records.append(record)
            if entity_type == ENTITY_CONVERSATION:
                conv_ids.add(entity_id)
            elif entity_type == ENTITY_MESSAGE:
                msg_ids.add(entity_id)
    except Exception as error:
        if is_table_missing(error):
            return set(), set(), [], False
        raise
    return conv_ids, msg_ids, records, True


def delete_conversation_cascade(client, conv_id):
    """删除会话行及其名下全部消息行"""
    write_rows(client, TABLE_CONVERSATIONS, [([('conversation_id', conv_id)], None)])

    victims = []
    try:
        rows = iter_range(
            client,
            TABLE_MESSAGES,
            [('conversation_id', conv_id), ('message_id', INF_MIN)],
            [('conversation_id', conv_id), ('message_id', INF_MAX)]
        )
        for row in rows:
            victims.append((
                [('conversation_id', conv_id), ('message_id', row.primary_key[1][1])],
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

    # 1. 先落墓碑：删除意图优先于内容写入，避免同一批里"删了又被写回"
    tombstone_rows = []
    accepted_deletions = 0
    pushed_conv_tombstones = set()
    pushed_msg_tombstones = set()

    for item in deletions:
        if not isinstance(item, dict):
            continue
        entity_type = as_text(item.get('type')).strip()
        entity_id = as_text(item.get('id')).strip()
        if entity_type not in (ENTITY_CONVERSATION, ENTITY_MESSAGE) or not entity_id:
            continue
        deleted_at = as_int(item.get('deletedAt') or item.get('deleted_at'), now_ms)
        conversation_id = as_text(item.get('conversationId') or item.get('conversation_id'))
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
            pushed_msg_tombstones.add((conversation_id, entity_id))

    deletions_supported = True
    if tombstone_rows:
        try:
            write_rows(client, TABLE_DELETIONS, tombstone_rows)
        except Exception as error:
            if is_table_missing(error):
                deletions_supported = False
                accepted_deletions = 0
                pushed_conv_tombstones = set()
                pushed_msg_tombstones = set()
            else:
                raise

    if deletions_supported:
        for conv_id in pushed_conv_tombstones:
            delete_conversation_cascade(client, conv_id)
        orphan_msgs = [
            ([('conversation_id', conv_id), ('message_id', msg_id)], None)
            for conv_id, msg_id in pushed_msg_tombstones
            if conv_id and conv_id not in pushed_conv_tombstones
        ]
        write_rows(client, TABLE_MESSAGES, orphan_msgs)

    # 2. 读出全量墓碑，过滤掉针对已删除对象的写入。
    #    客户端正常是 pull-then-push，本地已应用远端删除；这里再兜一层，
    #    保证任何顺序下都不会有旧客户端把已删记录复活。
    known_conv_tombstones, known_msg_tombstones, _, table_present = load_tombstones(client)
    if not table_present:
        deletions_supported = False

    conv_rows = []
    skipped_conversations = 0
    for conv in conversations:
        if not isinstance(conv, dict):
            continue
        conv_id = as_text(conv.get('id')).strip()
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
        conv_id = as_text(msg.get('conversation_id') or msg.get('conversationId')).strip()
        msg_id = as_text(msg.get('id')).strip()
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
        sequence = as_int(item.get('sequence'))
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

    if sr_rows:
        try:
            write_rows(client, TABLE_SENSOR_READINGS, sr_rows)
        except Exception as error:
            if not is_table_missing(error):
                raise

    write_rows(client, TABLE_CONVERSATIONS, conv_rows)
    write_rows(client, TABLE_MESSAGES, msg_rows)

    result = {
        'success': True,
        'conversations_count': len(conv_rows),
        'messages_count': len(msg_rows),
        'sensor_readings_count': len(sr_rows),
        'deletions_count': accepted_deletions,
        'skipped_conversations': skipped_conversations,
        'skipped_messages': skipped_messages,
        'serverTime': int(time.time() * 1000)
    }
    if not deletions_supported:
        result['deletions_supported'] = False
        result['deletions_hint'] = (
            f"未找到墓碑表 '{TABLE_DELETIONS}'，删除无法跨端同步。"
            f"请在 Tablestore 控制台新建数据表 '{TABLE_DELETIONS}'，"
            "主键依次为 entity_type(字符串)、entity_id(字符串)。"
        )
    return result


def handle_pull(client, query_params):
    since = as_int(query_params.get('since'), 0)

    conv_tombstones, msg_tombstones, deletion_records, deletions_supported = load_tombstones(client)

    conversations_res = []
    for row in iter_range(
        client,
        TABLE_CONVERSATIONS,
        [('conversation_id', INF_MIN)],
        [('conversation_id', INF_MAX)]
    ):
        conv_id = row.primary_key[0][1]
        if conv_id in conv_tombstones:
            continue
        attrs = extract_attrs(row)
        updated_at = as_int(attrs.get('updated_at'))
        if updated_at >= since:
            conversations_res.append({
                'id': conv_id,
                'title': as_text(attrs.get('title')),
                'kind': as_text(attrs.get('kind'), 'text'),
                'deviceId': attrs.get('device_id') or None,
                'createdAt': as_int(attrs.get('created_at')),
                'updatedAt': updated_at
            })

    messages_res = []
    for row in iter_range(
        client,
        TABLE_MESSAGES,
        [('conversation_id', INF_MIN), ('message_id', INF_MIN)],
        [('conversation_id', INF_MAX), ('message_id', INF_MAX)]
    ):
        conv_id = row.primary_key[0][1]
        msg_id = row.primary_key[1][1]
        if conv_id in conv_tombstones or msg_id in msg_tombstones:
            continue
        attrs = extract_attrs(row)
        created_at = as_int(attrs.get('created_at'))
        if created_at >= since:
            try:
                tool_invs = json.loads(attrs.get('tool_invocations') or '[]')
            except Exception:
                tool_invs = []
            content = as_text(attrs.get('content'))
            messages_res.append({
                'id': msg_id,
                'conversation_id': conv_id,
                'role': as_text(attrs.get('role'), 'user'),
                'text': content,
                'content': content,
                'createdAt': created_at,
                'toolInvocations': tool_invs
            })

    # 墓碑始终整表返回：它是"删除事实"的唯一载体，漏掉一条就意味着某端复活记录。
    # 单用户量级很小；日后需要收敛可在此按 since 过滤并配合各端保留期清理。
    sensor_readings_res = []
    try:
        for row in iter_range(
            client,
            TABLE_SENSOR_READINGS,
            [('device_id', INF_MIN), ('sequence', INF_MIN)],
            [('device_id', INF_MAX), ('sequence', INF_MAX)]
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
    except Exception as error:
        if not is_table_missing(error):
            raise

    result = {
        'success': True,
        'conversations': conversations_res,
        'messages': messages_res,
        'sensorReadings': sensor_readings_res,
        'sensor_readings': sensor_readings_res,
        'deletions': deletion_records,
        'serverTime': int(time.time() * 1000)
    }
    if not deletions_supported:
        result['deletions_supported'] = False
        result['deletions_hint'] = (
            f"未找到墓碑表 '{TABLE_DELETIONS}'，删除无法跨端同步。"
            f"请在 Tablestore 控制台新建数据表 '{TABLE_DELETIONS}'，"
            "主键依次为 entity_type(字符串)、entity_id(字符串)。"
        )
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
