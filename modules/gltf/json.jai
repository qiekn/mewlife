// ----------------------------------------------------------------------------: jaison 适配
//
// glTF 加载器只读不写，这里给 jaison 的 JSON_Value 树包一层"找不到就返回默认值"的取值函数，
// 免得每个字段都要先判空、再判类型。

Json :: JSON_Value;

json_parse :: (text: string) -> *Json, bool {
    ok, value := json_parse_string(text);
    if !ok return null, false;
    root := New(Json);
    root.* = value;
    return root, true;
}

json_release :: (root: *Json) {
    if root == null return;
    json_free(root.*);
    free(root);
}

// 对象成员；不存在或类型不对返回 null。
json_get :: (node: *Json, key: string) -> *Json {
    if node == null || node.type != .OBJECT return null;
    return table_find_pointer(node.object, key);
}

json_count :: (node: *Json) -> s64 {
    if node == null || node.type != .ARRAY return 0;
    return node.array.count;
}

json_at :: (node: *Json, index: s64) -> *Json {
    if node == null || node.type != .ARRAY || index < 0 || index >= node.array.count return null;
    return *node.array[index];
}

json_number :: (node: *Json, default: float64 = 0) -> float64 {
    if node == null || node.type != .NUMBER return default;
    return node.number;
}

json_float :: (node: *Json, key: string, default: float = 0) -> float {
    return cast(float) json_number(json_get(node, key), default);
}

json_int :: (node: *Json, key: string, default: s64 = -1) -> s64 {
    return cast(s64) json_number(json_get(node, key), cast(float64) default);
}

json_string :: (node: *Json, default := "") -> string {
    if node == null || node.type != .STRING return default;
    return node.str;
}

json_bool :: (node: *Json, key: string, default := false) -> bool {
    member := json_get(node, key);
    if member == null || member.type != .BOOLEAN return default;
    return member.boolean;
}

#import "Basic";
#import "Hash_Table";
#import "jaison";
