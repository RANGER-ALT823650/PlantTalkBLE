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

def get_cors_headers():
    return {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS, DELETE',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400'
    }

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

    # 校验 Token
    auth_token = headers.get('x-auth-token') or headers.get('X-Auth-Token') or ''
    expected_token = os.environ.get('AUTH_TOKEN', '').strip()
    if expected_token and auth_token != expected_token:
        return 401, cors_headers, {'error': 'Unauthorized: 无效的 x-auth-token'}

    client = get_ots_client()

    clean_path = path.rstrip('/')
    is_push = (
        clean_path in ('/sync/push', '/messages', '/push') or 
        (method == 'POST' and ('conversations' in body_data or 'messages' in body_data)) or
        (method == 'POST' and clean_path in ('', '/'))
    )

    is_pull = (
        clean_path in ('/sync/pull', '/messages', '/pull') or
        (method == 'GET' and (clean_path in ('', '/') or 'since' in query_params))
    )

    # 1. POST 推送逻辑
    if method == 'POST' and is_push:
        conversations = body_data.get('conversations', [])
        messages = body_data.get('messages', [])

        for conv in conversations:
            conv_id = str(conv['id'])
            primary_key = [('conversation_id', conv_id)]
            attribute_columns = [
                ('title', str(conv.get('title', '未命名对话'))),
                ('kind', str(conv.get('kind', 'text'))),
                ('device_id', str(conv.get('deviceId') or '')),
                ('created_at', int(conv.get('createdAt', time.time() * 1000))),
                ('updated_at', int(conv.get('updatedAt', time.time() * 1000)))
            ]
            row = Row(primary_key, attribute_columns)
            condition = Condition(RowExistenceExpectation.IGNORE)
            client.put_row('conversations', row, condition)

        for msg in messages:
            conv_id = str(msg.get('conversation_id') or msg.get('conversationId') or '')
            msg_id = str(msg['id'])
            if not conv_id:
                continue

            primary_key = [
                ('conversation_id', conv_id),
                ('message_id', msg_id)
            ]
            attribute_columns = [
                ('role', str(msg.get('role', 'user'))),
                ('content', str(msg.get('text') or msg.get('content') or '')),
                ('created_at', int(msg.get('createdAt', time.time() * 1000))),
                ('tool_invocations', json.dumps(msg.get('toolInvocations', [])))
            ]
            row = Row(primary_key, attribute_columns)
            condition = Condition(RowExistenceExpectation.IGNORE)
            client.put_row('messages', row, condition)

        return 200, cors_headers, {
            'success': True,
            'conversations_count': len(conversations),
            'messages_count': len(messages)
        }

    # 2. GET 拉取逻辑
    elif method == 'GET' and is_pull:
        since = int(query_params.get('since', 0))

        start_pk_conv = [('conversation_id', INF_MIN)]
        end_pk_conv = [('conversation_id', INF_MAX)]
        _, _, conv_rows, _ = client.get_range(
            'conversations', Direction.FORWARD, start_pk_conv, end_pk_conv, columns_to_get=[], limit=500
        )

        conversations_res = []
        for row in conv_rows:
            conv_id = row.primary_key[0][1]
            attrs = extract_attrs(row)
            updated_at = attrs.get('updated_at', 0)
            if updated_at >= since:
                conversations_res.append({
                    'id': conv_id,
                    'title': attrs.get('title', ''),
                    'kind': attrs.get('kind', 'text'),
                    'deviceId': attrs.get('device_id') or None,
                    'createdAt': attrs.get('created_at', 0),
                    'updatedAt': updated_at
                })

        start_pk_msg = [('conversation_id', INF_MIN), ('message_id', INF_MIN)]
        end_pk_msg = [('conversation_id', INF_MAX), ('message_id', INF_MAX)]
        _, _, msg_rows, _ = client.get_range(
            'messages', Direction.FORWARD, start_pk_msg, end_pk_msg, columns_to_get=[], limit=1000
        )

        messages_res = []
        for row in msg_rows:
            conv_id = row.primary_key[0][1]
            msg_id = row.primary_key[1][1]
            attrs = extract_attrs(row)
            created_at = attrs.get('created_at', 0)
            if created_at >= since:
                tool_invs_str = attrs.get('tool_invocations', '[]')
                try: tool_invs = json.loads(tool_invs_str)
                except Exception: tool_invs = []
                content = attrs.get('content', '')
                messages_res.append({
                    'id': msg_id,
                    'conversation_id': conv_id,
                    'role': attrs.get('role', 'user'),
                    'text': content,
                    'content': content,
                    'createdAt': created_at,
                    'toolInvocations': tool_invs
                })

        return 200, cors_headers, {
            'success': True,
            'conversations': conversations_res,
            'messages': messages_res
        }

    else:
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
