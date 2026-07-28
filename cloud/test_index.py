# -*- coding: utf-8 -*-
"""
云同步函数的删除语义测试。

真机没装 tablestore SDK，这里注入一个内存假实现，既验证删除不会被复活，
也顺带验证代码只用了 SDK 真实存在的调用形态。
运行: python3 cloud/test_index.py
"""
import json
import os
import sys
import types
import unittest

CLOUD_DIR = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- fake SDK

class INF_MIN:
    pass


class INF_MAX:
    pass


class Direction:
    FORWARD = 'FORWARD'


class RowExistenceExpectation:
    IGNORE = 'IGNORE'


class Condition:
    def __init__(self, expectation):
        self.expectation = expectation


class Row:
    def __init__(self, primary_key, attribute_columns=None):
        self.primary_key = primary_key
        self.attribute_columns = attribute_columns


class PutRowItem:
    def __init__(self, row, condition):
        self.row = row
        self.condition = condition


class DeleteRowItem:
    def __init__(self, row, condition):
        self.row = row
        self.condition = condition


class TableInBatchWriteRowItem:
    def __init__(self, table_name, row_items):
        self.table_name = table_name
        self.row_items = row_items


class BatchWriteRowRequest:
    def __init__(self):
        self.items = []

    def add(self, item):
        self.items.append(item)


class FakeOTSClient:
    """按 (table, pk_tuple) -> attrs 存储的最小 Tablestore 替身"""

    def __init__(self, tables):
        # tables: {table_name: pk_column_names}
        self.schema = tables
        self.rows = {name: {} for name in tables}
        self.range_calls = 0
        self.row_gets = 0

    # -- helpers
    def _pk_tuple(self, primary_key):
        return tuple(value for _, value in primary_key)

    def _require_table(self, table_name):
        if table_name not in self.rows:
            raise RuntimeError(
                f"ErrorCode: OTSObjectNotExist, ErrorMessage: Requested table {table_name} does not exist"
            )

    def _require_table_for_range(self, table_name):
        """
        GetRange 报缺表用的是另一套错误码和文案（OTSParameterInvalid /
        "Request table not exist"），线上就是这条把 handle_pull 打成了 500。
        替身必须复刻这个差异，否则测试测不出降级逻辑漏掉的分支。
        """
        if table_name not in self.rows:
            raise RuntimeError(
                "ErrorCode: OTSParameterInvalid, ErrorMessage: Request table not exist, RequestID: fake"
            )

    # -- SDK surface used by index.py
    def put_row(self, table_name, row, condition):
        self._require_table(table_name)
        self.rows[table_name][self._pk_tuple(row.primary_key)] = list(row.attribute_columns or [])

    def get_row(self, table_name, primary_key, columns_to_get=None):
        """真实 SDK 返回 (consumed, row, next_token)，行不存在时 row 为 None。"""
        self._require_table(table_name)
        self.row_gets += 1
        pk = self._pk_tuple(primary_key)
        attrs = self.rows[table_name].get(pk)
        if attrs is None:
            return None, None, None
        pk_names = self.schema[table_name]
        stored_pk = [(pk_names[i], value) for i, value in enumerate(pk)]
        return None, Row(stored_pk, list(attrs)), None

    def delete_row(self, table_name, row, condition):
        self._require_table(table_name)
        self.rows[table_name].pop(self._pk_tuple(row.primary_key), None)

    def batch_write_row(self, request):
        for table_item in request.items:
            self._require_table(table_item.table_name)
            for row_item in table_item.row_items:
                if isinstance(row_item, DeleteRowItem):
                    self.delete_row(table_item.table_name, row_item.row, None)
                else:
                    self.put_row(table_item.table_name, row_item.row, None)

    @staticmethod
    def _sortable(value):
        """让 INF_MIN < 任意值 < INF_MAX，从而能直接比较主键顺序"""
        if value is INF_MIN:
            return (0,)
        if value is INF_MAX:
            return (2,)
        return (1, value)

    def _sortable_key(self, values):
        return tuple(self._sortable(value) for value in values)

    def get_range(self, table_name, direction, start_pk, end_pk, columns_to_get=None, limit=None):
        self._require_table_for_range(table_name)
        self.range_calls += 1
        pk_names = self.schema[table_name]
        ordered = sorted(self.rows[table_name].items(), key=lambda kv: self._sortable_key(kv[0]))

        # Tablestore 的区间语义：start 闭、end 开
        low = self._sortable_key([value for _, value in start_pk])
        high = self._sortable_key([value for _, value in end_pk])
        selected = [
            (pk, attrs)
            for pk, attrs in ordered
            if low <= self._sortable_key(pk) < high
        ]

        # 用小页大小强制走翻页路径，暴露只取首页就返回的 bug
        page = selected[:limit] if limit else selected
        rows = [Row([(pk_names[i], value) for i, value in enumerate(pk)], attrs) for pk, attrs in page]

        # next_start_primary_key 指向下一个待读取的行（闭区间起点）
        next_start = None
        if limit and len(selected) > limit:
            next_pk = selected[limit][0]
            next_start = [(pk_names[i], value) for i, value in enumerate(next_pk)]
        return None, next_start, rows, None


def install_fake_sdk():
    module = types.ModuleType('tablestore')
    module.OTSClient = FakeOTSClient
    module.RowExistenceExpectation = RowExistenceExpectation
    module.Condition = Condition
    module.Direction = Direction
    module.Row = Row
    module.INF_MIN = INF_MIN
    module.INF_MAX = INF_MAX
    module.BatchWriteRowRequest = BatchWriteRowRequest
    module.TableInBatchWriteRowItem = TableInBatchWriteRowItem
    module.PutRowItem = PutRowItem
    module.DeleteRowItem = DeleteRowItem
    sys.modules['tablestore'] = module


install_fake_sdk()
sys.path.insert(0, CLOUD_DIR)
import index  # noqa: E402


# ---------------------------------------------------------------- helpers

FULL_TABLES = {
    'conversations': ['conversation_id'],
    'messages': ['conversation_id', 'message_id'],
    'deletions': ['entity_type', 'entity_id'],
    'sensor_readings': ['device_id', 'sequence'],
    'commands': ['command_id'],
    'device_pending': ['device_id'],
}
LEGACY_TABLES = {
    'conversations': ['conversation_id'],
    'messages': ['conversation_id', 'message_id'],
}
# 老部署：建了指令表但没建待办索引表，轮询要降级成扫表。
COMMAND_TABLES_WITHOUT_INDEX = {
    'sensor_readings': ['device_id', 'sequence'],
    'commands': ['command_id'],
}


def make_reading(device_id='d1', sequence=1, recorded=1000):
    return {
        'deviceId': device_id,
        'sequence': sequence,
        'recordedAt': recorded,
        'timestampEstimated': False,
        'soilRaw': 1234,
        'temperature': 21.5,
        'humidity': 40.0,
        'lightLux': 300.0,
    }


TEST_TOKEN = 'test-token'


def call(client, method, path, body=None, query=None, headers=None):
    """
    发一次请求。默认带上正确的 x-auth-token —— AUTH_TOKEN 现在是强制的，
    不带 token 的调用一律被拒，那是鉴权测试自己的事。
    """
    index.get_ots_client = lambda: client
    merged_headers = {'x-auth-token': TEST_TOKEN}
    if headers is not None:
        merged_headers = dict(headers)
    status, _, data = index.main_logic(method, path, merged_headers, query or {}, body or {})
    return status, data


def make_conv(conv_id, title='对话', updated=1000):
    return {'id': conv_id, 'title': title, 'kind': 'text', 'createdAt': 900, 'updatedAt': updated}


def make_msg(conv_id, msg_id, text='你好', created=1000):
    return {'id': msg_id, 'conversation_id': conv_id, 'role': 'user', 'text': text, 'createdAt': created}


# 同一个 UUID 的两种写法：Web 生成小写，iOS 的 UUID.uuidString 生成大写。
LOWER_ID = '8f14e45f-ceea-467a-9c1d-2b0e5f0a1234'
UPPER_ID = LOWER_ID.upper()
LOWER_MSG = 'a1b2c3d4-0000-4000-8000-000000000001'
UPPER_MSG = LOWER_MSG.upper()


class DeletionSyncTests(unittest.TestCase):
    def setUp(self):
        os.environ['AUTH_TOKEN'] = TEST_TOKEN
        self.client = FakeOTSClient(FULL_TABLES)

    def push(self, **body):
        status, data = call(self.client, 'POST', '/sync/push', body)
        self.assertEqual(status, 200, data)
        return data

    def pull(self, since=0):
        status, data = call(self.client, 'GET', '/sync/pull', query={'since': str(since)})
        self.assertEqual(status, 200, data)
        return data

    def test_push_then_pull_roundtrip(self):
        self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1')])
        pulled = self.pull()
        self.assertEqual([c['id'] for c in pulled['conversations']], ['c1'])
        self.assertEqual([m['id'] for m in pulled['messages']], ['m1'])

    def test_deleted_conversation_is_not_resurrected_by_pull(self):
        self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1')])
        # A 端删除会话
        result = self.push(deletions=[{'type': 'conversation', 'id': 'c1', 'deletedAt': 2000}])
        self.assertEqual(result['deletions_count'], 1)

        pulled = self.pull()
        self.assertEqual(pulled['conversations'], [])
        self.assertEqual(pulled['messages'], [], '会话删除必须级联清掉它名下的消息')
        self.assertEqual(
            [(d['type'], d['id']) for d in pulled['deletions']],
            [('conversation', 'c1')],
            '墓碑要回传给其他端，否则别的端不知道该删什么',
        )

    def test_deletion_actually_frees_storage_rows(self):
        """删除必须真的清掉存储行，否则 Tablestore 里会一直堆着付费数据。"""
        self.push(
            conversations=[make_conv('c1'), make_conv('c2')],
            messages=[make_msg('c1', 'm1'), make_msg('c1', 'm2'), make_msg('c2', 'm3')],
        )
        self.push(deletions=[{'type': 'conversation', 'id': 'c1', 'deletedAt': 2000}])

        self.assertNotIn(('c1',), self.client.rows['conversations'])
        self.assertIn(('c2',), self.client.rows['conversations'])
        remaining_msgs = sorted(self.client.rows['messages'].keys())
        self.assertEqual(remaining_msgs, [('c2', 'm3')], '会话名下的消息行也要一并删掉')

    def test_stale_client_cannot_resurrect_deleted_conversation(self):
        """B 端还不知道删除，重新推送同一条会话时云端必须拒收。"""
        self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1')])
        self.push(deletions=[{'type': 'conversation', 'id': 'c1', 'deletedAt': 2000}])

        result = self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1')])
        self.assertEqual(result['conversations_count'], 0)
        self.assertEqual(result['messages_count'], 0)
        self.assertEqual(result['skipped_conversations'], 1)
        self.assertEqual(result['skipped_messages'], 1)

        pulled = self.pull()
        self.assertEqual(pulled['conversations'], [])
        self.assertEqual(pulled['messages'], [])

    def test_single_message_deletion_keeps_conversation(self):
        self.push(
            conversations=[make_conv('c1')],
            messages=[make_msg('c1', 'm1'), make_msg('c1', 'm2')],
        )
        self.push(deletions=[
            {'type': 'message', 'id': 'm1', 'conversationId': 'c1', 'deletedAt': 2000},
        ])

        pulled = self.pull()
        self.assertEqual([c['id'] for c in pulled['conversations']], ['c1'])
        self.assertEqual([m['id'] for m in pulled['messages']], ['m2'])

    def test_delete_and_write_in_one_batch_lets_delete_win(self):
        """同一批里既有删除又有写入时，删除优先，不能出现删了又被写回。"""
        self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1')])
        self.push(
            conversations=[make_conv('c1')],
            messages=[make_msg('c1', 'm1')],
            deletions=[{'type': 'conversation', 'id': 'c1', 'deletedAt': 2000}],
        )
        pulled = self.pull()
        self.assertEqual(pulled['conversations'], [])
        self.assertEqual(pulled['messages'], [])

    def test_since_filters_older_records(self):
        self.push(
            conversations=[make_conv('c1', updated=1000), make_conv('c2', updated=5000)],
            messages=[make_msg('c1', 'm1', created=1000), make_msg('c2', 'm2', created=5000)],
        )
        pulled = self.pull(since=3000)
        self.assertEqual([c['id'] for c in pulled['conversations']], ['c2'])
        self.assertEqual([m['id'] for m in pulled['messages']], ['m2'])

    def test_pull_pages_beyond_one_page(self):
        """原实现固定 limit 截断会静默丢数据，这里用超过页大小的量验证翻页。"""
        original_page_size = index.RANGE_PAGE_SIZE
        index.RANGE_PAGE_SIZE = 10
        try:
            convs = [make_conv(f'c{i:03d}') for i in range(25)]
            msgs = [make_msg(f'c{i:03d}', f'm{i:03d}') for i in range(25)]
            self.push(conversations=convs, messages=msgs)
            pulled = self.pull()
            self.assertEqual(len(pulled['conversations']), 25)
            self.assertEqual(len(pulled['messages']), 25)
        finally:
            index.RANGE_PAGE_SIZE = original_page_size

    def test_missing_tombstone_table_reports_hint_and_keeps_syncing(self):
        """老部署没建墓碑表时，消息仍能同步，但要明确告知删除传不过去。"""
        legacy = FakeOTSClient(LEGACY_TABLES)
        status, data = call(legacy, 'POST', '/sync/push', {
            'conversations': [make_conv('c1')],
            'messages': [make_msg('c1', 'm1')],
            'deletions': [{'type': 'conversation', 'id': 'c1', 'deletedAt': 2000}],
        })
        self.assertEqual(status, 200, data)
        self.assertFalse(data['deletions_supported'])
        self.assertIn('deletions', data['deletions_hint'])
        self.assertEqual(data['conversations_count'], 1, '墓碑表缺失不应阻断普通消息同步')

        status, pulled = call(legacy, 'GET', '/sync/pull', query={'since': '0'})
        self.assertEqual(status, 200, pulled)
        self.assertFalse(pulled['deletions_supported'])
        self.assertEqual(pulled['deletions'], [])

    def test_missing_sensor_table_does_not_break_pull(self):
        """
        线上就是这个场景：只建了会话相关的表，拉取时 sensor_readings 缺失。
        以前 GetRange 的 OTSParameterInvalid 没被识别成"缺表"，整个 pull 变成 500。
        """
        legacy = FakeOTSClient(LEGACY_TABLES)
        status, data = call(legacy, 'POST', '/sync/push', {
            'conversations': [make_conv('c1')],
            'messages': [make_msg('c1', 'm1')],
            'sensorReadings': [make_reading()],
        })
        self.assertEqual(status, 200, data)
        # 读数表不存在，就不能报成已上传
        self.assertEqual(data['sensor_readings_count'], 0)
        self.assertIn('sensor_readings', data['missing_tables'])

        status, pulled = call(legacy, 'GET', '/sync/pull', query={'since': '0'})
        self.assertEqual(status, 200, pulled)
        self.assertEqual([c['id'] for c in pulled['conversations']], ['c1'])
        self.assertEqual(pulled['sensorReadings'], [])
        self.assertIn('sensor_readings', pulled['missing_tables'])
        self.assertIn('device_id', pulled['deletions_hint'])

    def test_sensor_readings_roundtrip(self):
        self.push(sensorReadings=[make_reading(sequence=1), make_reading(sequence=2)])
        pulled = self.pull()
        self.assertEqual([r['sequence'] for r in pulled['sensorReadings']], [1, 2])
        self.assertEqual(pulled['sensorReadings'][0]['soilRaw'], 1234)

    def test_future_estimated_batch_is_anchored_to_server_receive_time(self):
        readings = [
            {
                **make_reading(sequence=1, recorded=1_600_000),
                'receivedAt': 1_600_000,
                'timestampEstimated': True,
            },
            {
                **make_reading(sequence=2, recorded=1_900_000),
                'receivedAt': 1_900_000,
                'timestampEstimated': True,
            },
        ]
        rows = index.sensor_reading_rows(readings, server_received_at=1_000_000)
        attrs = [{name: value for name, value in row_attrs} for _, row_attrs in rows]

        # Shift the run together: its five-minute spacing survives, while the
        # newest estimate can no longer appear after the server received it.
        self.assertEqual([item['recorded_at'] for item in attrs], [700_000, 1_000_000])
        self.assertEqual([item['received_at'] for item in attrs], [1_000_000, 1_000_000])

    def test_reading_without_sequence_is_rejected(self):
        """缺 sequence 的读数若落到 sequence=0，多条读数会互相覆盖。"""
        no_seq = make_reading()
        no_seq.pop('sequence')
        data = self.push(sensorReadings=[no_seq, make_reading(sequence=5)])
        self.assertEqual(data['sensor_readings_count'], 1)
        self.assertEqual([r['sequence'] for r in self.pull()['sensorReadings']], [5])

    def test_auth_token_is_enforced(self):
        os.environ['AUTH_TOKEN'] = 'secret'
        index.get_ots_client = lambda: self.client
        status, _, data = index.main_logic('GET', '/sync/pull', {}, {'since': '0'}, {})
        self.assertEqual(status, 401)
        status, _, data = index.main_logic(
            'GET', '/sync/pull', {'x-auth-token': 'secret'}, {'since': '0'}, {}
        )
        self.assertEqual(status, 200, data)

    def test_missing_auth_token_config_stops_serving(self):
        """
        未配置 AUTH_TOKEN 时必须拒绝服务而不是放行。
        /command/create 能驱动用户家里的硬件采样，开放接口等于交出设备控制权。
        """
        os.environ.pop('AUTH_TOKEN', None)
        index.get_ots_client = lambda: self.client
        for method, path, query in (
            ('GET', '/sync/pull', {'since': '0'}),
            ('POST', '/command/create', {}),
            ('GET', '/command/poll', {'deviceId': 'd1'}),
        ):
            status, _, data = index.main_logic(method, path, {}, query, {})
            self.assertEqual(status, 503, f'{method} {path} 应停止服务，实际 {status}')
            self.assertIn('AUTH_TOKEN', data['error'])

    def test_malformed_payload_does_not_crash(self):
        result = self.push(
            conversations=[{'title': '缺 id'}, None, make_conv('c1')],
            messages=[{'id': 'm0'}, make_msg('c1', 'm1')],
            deletions=[{'type': 'nope', 'id': 'x'}, {'type': 'conversation'}],
        )
        self.assertEqual(result['conversations_count'], 1)
        self.assertEqual(result['messages_count'], 1)
        self.assertEqual(result['deletions_count'], 0)

    def test_null_and_string_timestamps_are_normalized(self):
        self.push(
            conversations=[{'id': 'c1', 'title': None, 'kind': None, 'createdAt': None, 'updatedAt': '2500'}],
            messages=[{'id': 'm1', 'conversation_id': 'c1', 'role': None, 'text': None, 'createdAt': 2500.7}],
        )
        pulled = self.pull()
        conv = pulled['conversations'][0]
        self.assertEqual(conv['updatedAt'], 2500)
        self.assertEqual(conv['kind'], 'text')
        msg = pulled['messages'][0]
        self.assertEqual(msg['createdAt'], 2500)
        self.assertEqual(msg['text'], '')

    # ---- ID 大小写：iOS 的 UUID.uuidString 恒大写，浏览器恒小写 ----

    def test_uppercase_tombstone_deletes_lowercase_record(self):
        """iOS 删除 Web 建的记录：墓碑是大写，云端那行是小写，必须能对上。"""
        self.push(conversations=[make_conv(LOWER_ID)], messages=[make_msg(LOWER_ID, LOWER_MSG)])
        self.push(deletions=[{'type': 'conversation', 'id': UPPER_ID, 'deletedAt': 2000}])

        pulled = self.pull()
        self.assertEqual(pulled['conversations'], [], '大写墓碑没能删掉小写的那一行')
        self.assertEqual(pulled['messages'], [])
        self.assertEqual(self.client.rows['conversations'], {}, '存储行必须真的被清掉')

    def test_lowercase_tombstone_deletes_uppercase_record(self):
        """反向：Web 删除 iOS 建的记录。"""
        self.push(conversations=[make_conv(UPPER_ID)], messages=[make_msg(UPPER_ID, UPPER_MSG)])
        self.push(deletions=[{'type': 'conversation', 'id': LOWER_ID, 'deletedAt': 2000}])

        pulled = self.pull()
        self.assertEqual(pulled['conversations'], [])
        self.assertEqual(pulled['messages'], [])

    def test_deleted_record_stays_deleted_when_other_case_is_repushed(self):
        """删除后另一端用另一种大小写重推同一条：不能复活。"""
        self.push(conversations=[make_conv(LOWER_ID)], messages=[make_msg(LOWER_ID, LOWER_MSG)])
        self.push(deletions=[{'type': 'conversation', 'id': LOWER_ID, 'deletedAt': 2000}])

        result = self.push(
            conversations=[make_conv(UPPER_ID)], messages=[make_msg(UPPER_ID, UPPER_MSG)]
        )
        self.assertEqual(result['skipped_conversations'], 1)
        self.assertEqual(result['skipped_messages'], 1)
        self.assertEqual(self.pull()['conversations'], [])

    def test_message_tombstone_without_conversation_id_still_deletes(self):
        """老客户端的消息墓碑不带 conversationId，定点删除无从下手，也必须删掉。"""
        self.push(conversations=[make_conv('c1')], messages=[make_msg('c1', 'm1'), make_msg('c1', 'm2')])
        self.push(deletions=[{'type': 'message', 'id': 'M1', 'deletedAt': 2000}])

        pulled = self.pull()
        self.assertEqual([m['id'] for m in pulled['messages']], ['m2'])
        self.assertEqual([c['id'] for c in pulled['conversations']], ['c1'], '删一条消息不应带走会话')

    def test_case_twin_rows_collapse_into_one(self):
        """规范化之前留下的孪生行：拉取只应看到一条，且旧行被清掉。"""
        self.client.rows['conversations'][(UPPER_ID,)] = [
            ('title', '大写旧行'), ('kind', 'text'), ('device_id', ''),
            ('created_at', 900), ('updated_at', 1000),
        ]
        self.push(conversations=[make_conv(LOWER_ID, title='小写新行', updated=3000)])

        pulled = self.pull()
        self.assertEqual([c['id'] for c in pulled['conversations']], [LOWER_ID])
        self.assertEqual(pulled['conversations'][0]['title'], '小写新行')
        self.assertEqual(len(self.client.rows['conversations']), 1, '孪生行应被清理')

    def test_pull_returns_canonical_lowercase_ids(self):
        self.push(conversations=[make_conv(UPPER_ID)], messages=[make_msg(UPPER_ID, UPPER_MSG)])
        pulled = self.pull()
        self.assertEqual(pulled['conversations'][0]['id'], LOWER_ID)
        self.assertEqual(pulled['messages'][0]['id'], LOWER_MSG)
        self.assertEqual(pulled['messages'][0]['conversation_id'], LOWER_ID)

    def test_handler_event_shape_returns_json(self):
        index.get_ots_client = lambda: self.client
        response = index.handler(
            {
                'httpMethod': 'POST',
                'rawPath': '/sync/push',
                'headers': {'x-auth-token': TEST_TOKEN},
                'body': json.dumps({'conversations': [make_conv('c1')], 'messages': []}),
            },
            None,
        )
        self.assertEqual(response['statusCode'], 200)
        self.assertTrue(json.loads(response['body'])['success'])


class CommandMailboxTests(unittest.TestCase):
    """
    远程采样指令信箱（方案 A）。链路是
    App /command/create -> ESP32 /command/poll -> ESP32 /command/respond -> App /command/status。
    """

    def setUp(self):
        os.environ['AUTH_TOKEN'] = TEST_TOKEN
        self.client = FakeOTSClient(FULL_TABLES)
        self.clock = 1_000_000
        self.original_now_ms = index.now_ms
        index.now_ms = lambda: self.clock

    def tearDown(self):
        # now_ms 是模块级函数，冻结完必须还原，否则污染同进程内的其它测试。
        index.now_ms = self.original_now_ms

    def create(self, device_id='d1', action='refresh_sensor', client=None):
        status, data = call(
            client or self.client,
            'POST', '/command/create',
            {'deviceId': device_id, 'action': action},
        )
        self.assertEqual(status, 200, data)
        return data

    def poll(self, device_id='d1', client=None):
        status, data = call(
            client or self.client,
            'GET', '/command/poll', query={'deviceId': device_id},
        )
        self.assertEqual(status, 200, data)
        return data

    def respond(self, command_id, reading, client=None):
        status, data = call(
            client or self.client,
            'POST', '/command/respond',
            {'commandId': command_id, 'reading': reading},
        )
        self.assertEqual(status, 200, data)
        return data

    def status_of(self, command_id, client=None):
        status, data = call(
            client or self.client,
            'GET', '/command/status', query={'commandId': command_id},
        )
        self.assertEqual(status, 200, data)
        return data

    def test_full_roundtrip(self):
        created = self.create()
        self.assertEqual(created['status'], 'pending')

        polled = self.poll()
        self.assertTrue(polled['hasCommand'])
        self.assertEqual(polled['serverTime'], self.clock)
        self.assertEqual(polled['commandId'], created['commandId'])
        self.assertEqual(polled['action'], 'refresh_sensor')

        reading = make_reading(device_id='d1', sequence=42, recorded=1_000_500)
        responded = self.respond(created['commandId'], reading)
        self.assertTrue(responded['storedReading'])

        final = self.status_of(created['commandId'])
        self.assertEqual(final['status'], 'completed')
        self.assertEqual(final['reading']['sequence'], 42)

        # 回填的读数必须真的进了 sensor_readings，能被普通同步拉到
        status, pulled = call(self.client, 'GET', '/sync/pull', query={'since': '0'})
        self.assertEqual(status, 200, pulled)
        self.assertEqual([r['sequence'] for r in pulled['sensorReadings']], [42])

    def test_completed_command_is_not_polled_again(self):
        """指令取走并回填后必须从待办里消失，否则设备会反复采样同一条指令。"""
        created = self.create()
        self.poll()
        self.respond(created['commandId'], make_reading(sequence=7))
        self.assertFalse(self.poll()['hasCommand'])

    def test_poll_does_not_scan_commands_table(self):
        """
        ESP32 每几秒轮询一次。原实现从 INF_MIN 扫到 INF_MAX 找 pending，
        指令表只增不删，跑几个月后每次轮询都要扫全表。这里锁定"不扫表"。
        """
        # 先在 commands 表里堆一批已完成的历史指令，再发一条真正待办的
        for seq in range(5):
            self.respond(self.create()['commandId'], make_reading(sequence=90 + seq))
        pending = self.create()

        self.client.range_calls = 0
        polled = self.poll()
        self.assertTrue(polled['hasCommand'])
        self.assertEqual(polled['commandId'], pending['commandId'])
        self.assertEqual(self.client.range_calls, 0, '轮询不应触发任何 GetRange')

    def test_idle_poll_does_not_scan_either(self):
        """
        绝大多数轮询是空转（没有待办）。"索引行不存在"必须与"索引表不存在"
        区别对待，否则空闲轮询每次都降级扫表，开销回到原点。
        """
        self.respond(self.create()['commandId'], make_reading(sequence=1))
        self.client.range_calls = 0
        for _ in range(10):
            polled = self.poll()
            self.assertFalse(polled['hasCommand'])
            self.assertEqual(polled['serverTime'], self.clock)
        self.assertEqual(self.client.range_calls, 0, '空闲轮询同样不应扫表')

    def test_future_estimated_command_reading_is_clamped_when_received(self):
        created = self.create()
        reading = make_reading(sequence=71, recorded=self.clock + 600_000)
        reading['timestampEstimated'] = True
        self.respond(created['commandId'], reading)

        status, pulled = call(
            self.client,
            'GET',
            '/sync/pull',
            query={'since': '0'},
        )
        self.assertEqual(status, 200, pulled)
        stored = next(item for item in pulled['sensorReadings'] if item['sequence'] == 71)
        self.assertEqual(stored['recordedAt'], self.clock)
        self.assertEqual(stored['receivedAt'], self.clock)

    def test_expired_pending_is_not_delivered(self):
        """
        设备离线期间堆积的 pending 不能在它上线时被执行：
        用户会看到一条几天前请求的"即时"读数。
        """
        created = self.create()
        self.clock += index.COMMAND_TTL_MS + 1
        self.assertFalse(self.poll()['hasCommand'])

        expired = self.status_of(created['commandId'])
        self.assertEqual(expired['status'], 'expired')
        self.assertIn('联网', expired['error'])

    def test_command_within_ttl_is_still_delivered(self):
        created = self.create()
        self.clock += index.COMMAND_TTL_MS - 1
        self.assertEqual(self.poll()['commandId'], created['commandId'])

    def test_newer_command_replaces_expired_one(self):
        """过期指令清掉之后，新指令必须还能被轮询到。"""
        self.create()
        self.clock += index.COMMAND_TTL_MS + 1
        self.assertFalse(self.poll()['hasCommand'])

        fresh = self.create()
        self.assertEqual(self.poll()['commandId'], fresh['commandId'])

    def test_respond_does_not_clobber_a_newer_pending_command(self):
        """
        回填旧指令时无条件删索引，会把用户刚发的新指令一起抹掉，
        设备再也轮询不到它。
        """
        first = self.create()
        second = self.create()
        self.respond(first['commandId'], make_reading(sequence=1))

        polled = self.poll()
        self.assertTrue(polled['hasCommand'], '新指令不应被旧指令的回填清掉')
        self.assertEqual(polled['commandId'], second['commandId'])

    def test_poll_isolates_devices(self):
        self.create(device_id='d1')
        self.assertFalse(self.poll(device_id='d2')['hasCommand'])

    def test_reading_without_sequence_keeps_command_pending(self):
        """
        读数写不进去就不能把指令标成 completed：
        否则 App 看到 completed 却拿不到数据，无从判断问题在哪。
        """
        created = self.create()
        bad = make_reading(sequence=1)
        del bad['sequence']
        status, data = call(
            self.client, 'POST', '/command/respond',
            {'commandId': created['commandId'], 'reading': bad},
        )
        self.assertEqual(status, 200)
        self.assertFalse(data['success'])
        self.assertEqual(self.status_of(created['commandId'])['status'], 'pending')
        self.assertTrue(self.poll()['hasCommand'], '回填失败的指令应仍可被重试')

    def test_respond_to_unknown_command_is_rejected(self):
        status, data = call(
            self.client, 'POST', '/command/respond',
            {'commandId': 'cmd_does_not_exist', 'reading': make_reading(sequence=1)},
        )
        self.assertEqual(status, 200)
        self.assertFalse(data['success'])
        self.assertEqual(data['status'], 'not_found')

    def test_status_of_unknown_command(self):
        data = self.status_of('cmd_nope')
        self.assertFalse(data['success'])
        self.assertEqual(data['status'], 'not_found')

    def test_command_ids_do_not_collide_within_same_millisecond(self):
        """
        原实现的 ID 后缀是前缀毫秒数的后三位而非随机数，
        同一毫秒的两次请求会生成相同 ID，后者直接覆盖前者。
        """
        ids = {self.create()['commandId'] for _ in range(50)}
        self.assertEqual(len(ids), 50, '同一毫秒内创建的指令 ID 必须互不相同')

    def test_poll_falls_back_to_scan_without_index_table(self):
        """老部署没建 device_pending 表时，轮询降级为扫表而不是失败。"""
        legacy = FakeOTSClient(COMMAND_TABLES_WITHOUT_INDEX)
        created = self.create(client=legacy)
        self.assertIn('device_pending', created['pending_index_hint'])

        polled = self.poll(client=legacy)
        self.assertTrue(polled['hasCommand'])
        self.assertEqual(polled['commandId'], created['commandId'])

        self.respond(created['commandId'], make_reading(sequence=3), client=legacy)
        self.assertFalse(self.poll(client=legacy)['hasCommand'])

    def test_poll_without_command_table_reports_no_work(self):
        """两张表都没建时轮询也不能 500 —— 固件会把非 200 当成网络故障重试。"""
        bare = FakeOTSClient(LEGACY_TABLES)
        self.assertFalse(self.poll(client=bare)['hasCommand'])

    def test_create_without_command_table_explains_how_to_fix(self):
        bare = FakeOTSClient(LEGACY_TABLES)
        status, data = call(bare, 'POST', '/command/create', {'deviceId': 'd1'})
        self.assertEqual(status, 200)
        self.assertFalse(data['success'])
        self.assertIn('commands', data['error'])

    def test_respond_without_sensor_table_keeps_command_pending(self):
        no_sensor = FakeOTSClient({'commands': ['command_id'], 'device_pending': ['device_id']})
        created = self.create(client=no_sensor)
        status, data = call(
            no_sensor, 'POST', '/command/respond',
            {'commandId': created['commandId'], 'reading': make_reading(sequence=4)},
        )
        self.assertEqual(status, 200)
        self.assertFalse(data['success'])
        self.assertIn('sensor_readings', data['error'])
        self.assertEqual(self.status_of(created['commandId'], client=no_sensor)['status'], 'pending')


if __name__ == '__main__':
    unittest.main(verbosity=2)
