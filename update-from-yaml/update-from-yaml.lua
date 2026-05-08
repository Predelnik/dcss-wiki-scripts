local yaml = require 'tinyyaml'
local argparse = require 'argparse'

---@param s string
---@return string
local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

---@param tbl {[string]: any}
---@return string[]
local function _get_sorted_keys(tbl)
	local key_list = {}
	for key, _ in pairs(tbl) do
		table.insert(key_list, key)
	end
	table.sort(key_list)
	return key_list
end

---@param tbl (string|number)[]
---@return {[string|number]: boolean}
local function _get_value_set(tbl)
	---@type {[string|number]: boolean}
	local result = {}
	for _, value in ipairs(tbl) do
		result[value] = true
	end
	return result
end

---@param tbl any[]
---@param key_func fun(any): string
---@return {[string]: any}
local function _get_key_map(tbl, key_func)
	---@type {[string]: any}
	local result = {}
	for _, value in ipairs(tbl) do
		result[key_func(value)] = value
	end
	return result
end

---@param value {[any]: any}
---@param indent integer
---@param level integer
---@param path string
---@param spec_tbl? {[string]: SpecValue}
---@return string
local function _table_dump_impl(value, indent, level, path, spec_tbl)
	local indent_str
	---@type string?
	local next_indent_str
	local inline = false
	local final_comma = false
	if spec_tbl ~= nil and spec_tbl[path] ~= nil then
		inline = spec_tbl[path].inline or false
		final_comma = spec_tbl[path].final_comma or false
	end
	---@type integer
	local next_level
	indent_str = string.rep(" ", level * indent)
	if inline then
		next_indent_str = ''
		next_level = 0
	else
		next_indent_str = string.rep(" ", (level + 1) * indent)
		next_level = level + 1
	end
	if type(value) == "table" then
		---@type any[]
		local list = {}
		local is_array = true
		for key, _ in pairs(value) do
			table.insert(list, key)
			if type(key) ~= "number" then
				is_array = false
			end
		end
		local line_end_after_element = inline and '' or '\n'
		local rep = indent_str .. "{" .. line_end_after_element
		if is_array then
			for i, element in ipairs(value) do
				local comma = (i == #value) and (final_comma and "," or "") or ", "
				local element_dump = _table_dump_impl(element, indent, next_level, path .. '.element', spec_tbl)
				element_dump = trim(element_dump)
				rep = rep .. string.format("%s%s%s%s", next_indent_str, element_dump, comma, line_end_after_element)
			end
		else
			table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
			if spec_tbl and spec_tbl[path] then
				if spec_tbl[path].order then
					---@type string[]
					list = spec_tbl[path].order
				end
			end
			local last_key_index = #list
			local last_key = list[last_key_index]
			while value[last_key] == nil do
				last_key_index = last_key_index - 1
				last_key = list[last_key_index]
			end
			for _, key in ipairs(list) do
				local keyRep = key
				if type(key) == "string" then
					---@cast key string
					---@type string, number
					local result, cnt = key:gsub("__QUOTED__", "")
					if cnt > 0 then
						key = result
						keyRep = string.format("[%q]", tostring(key))
					elseif string.find(key, " ") then
						keyRep = string.format("[%q]", tostring(key))
					end
				end
				local element = value[key]
				if element ~= nil then
					local next_path = path .. '.' .. key
					local element_dump = _table_dump_impl(element, indent, next_level, next_path, spec_tbl)
					element_dump = trim(element_dump)
					local comma = key == last_key and (final_comma and "," or "") or ", "
					local finish = line_end_after_element == '\n' and line_end_after_element or ''
					rep = rep ..
						string.format("%s%s = %s%s%s",
							next_indent_str,
							keyRep,
							element_dump,
							comma,
							finish
						)
				end
			end
		end
		if not inline then
			rep = rep .. indent_str .. "}"
		else
			rep = rep .. "}"
		end
		return rep
	elseif type(value) == "string" then
		if string.find(value, '\n') or (spec_tbl and spec_tbl[path] and (spec_tbl[path].multiline or false)) then
			return indent_str .. string.format("[=[%s]=]", value)
		else
			return indent_str .. string.format("%q", value)
		end
	else
		return indent_str .. tostring(value)
	end
end

local function _table_dump_simple(value)
	return _table_dump_impl(value, 2, 0, '', nil)
end

local function _table_dump(data, spec_tbl)
	assert(data ~= nil)
	local result = "local m = {}\n"
	local keys = _get_sorted_keys(data)
	for _, key in ipairs(keys) do
		result = result .. string.format("m[%q] = ", key) .. _table_dump_impl(data[key], 2, 0, 'root', spec_tbl) .. "\n"
	end
	result = result .. "return m\n"
	return result
end

---@class StaticContext
---@field name string
---@field spec_tbl? {[string]: SpecValue}
---@field log string
---@field transfer_type string
local StaticContext = {}

---@return self
function StaticContext:new(o)
	o = o or {} -- create object if user does not provide one
	setmetatable(o, self)
	self.__index = self
	return o
end

---@param log_line string
---@param action? fun()
---@param is_small_change? boolean
---@return boolean
function StaticContext:conditional_update(log_line, action, is_small_change)
	local answer = 'y'
	if self.transfer_type == 'skip_small' and is_small_change then
		return false
	end
	if self.transfer_type == "confirm" then
		print(string.format(log_line .. " Update (y/n)?"))
		answer = io.read()
	end
	if answer == 'y' then
		self.log = self.log .. log_line .. '\n'
		if action then
			action()
		end
		return true
	end
	return false
end

---@class SpecValue
---@field order? string[]
---@field key? string
---@field compare_key? string
---@field inline? boolean
---@field multiline? boolean
---@field final_comma? boolean

---@class ContextBase
---@field path string
---@field spec_path string

---@class AnyContext : ContextBase
---@field new_data {[any]: any} | string | number
---@field cur_data {[any]: any} | string | number

---@class ArrayContext : ContextBase
---@field new_array any[]
---@field cur_array any[]

---@class DictionaryContext : ContextBase
---@field new_dictionary {[any]: any}
---@field cur_dictionary {[any]: any}

---@type fun(context: AnyContext, static_context: StaticContext): boolean
local _transfer_any

---@param context ArrayContext
---@param static_context StaticContext
local function _transfer_array(context, static_context)
	if type(context.new_array[1]) == "table" then
		---@type string?
		local compare_key = nil
		---@type string[]?
		if static_context.spec_tbl ~= nil then
			local spec_element = static_context.spec_tbl[context.spec_path .. '.element']
			if spec_element ~= nil then
				compare_key = spec_element.sort_key or spec_element.compare_key
			end
		end
		if compare_key == nil then
			for i = 1, math.min(#context.cur_array, #context.new_array) do
				---@type AnyContext
				local new_context = {
					new_data = context.new_array[i],
					cur_data = context.cur_array[i],
					path = context.path .. '[' .. i .. ']',
					spec_path = context.spec_path .. '.element'
				}
				_transfer_any(new_context, static_context)
			end
			for i = #context.cur_array + 1, #context.new_array do
				local log_line = string.format("%s: %s 'missing' -> '%s'.", static_context.name, context.path,
					_table_dump_simple(context.new_array[i]))
				static_context:conditional_update(log_line,
					function() table.insert(context.cur_array, context.new_array[i]) end)
			end
			for i = #context.new_array + 1, #context.cur_array do
				local log_line = string.format("%s: %s.element '%s' -> 'removed'.", static_context.name, context
					.path,
					_table_dump_simple(context.cur_array[i]))
				static_context:conditional_update(log_line,
					function() context.cur_array[i] = nil end)
			end
		else
			local cur_map = _get_key_map(context.cur_array, function(val) return val[compare_key] end)
			local new_map = _get_key_map(context.new_array, function(val) return val[compare_key] end)
			local keys = _get_sorted_keys(new_map)
			for _, key in ipairs(keys) do
				local value = new_map[key]
				if not cur_map[key] then
					local log_line = string.format("%s: %s 'missing' -> '%s' data.", static_context.name,
						context.path,
						key)
					static_context:conditional_update(log_line,
						function() table.insert(context.cur_array, value) end)
				else
					---@type AnyContext
					local new_context =
					{
						new_data = value,
						cur_data = cur_map[key],
						path = context.path .. '["' .. key .. '"]',
						spec_path = context.spec_path .. '.element'
					}
					_transfer_any(new_context, static_context)
				end
			end
			---@type {[string]:boolean}
			local to_remove_set = {}
			local keys = _get_sorted_keys(cur_map)
			for _, key in ipairs(keys) do
				if new_map[key] == nil then
					local log_line = string.format("%s: %s '%s' data -> 'removed'.", static_context.name,
						context.path,
						key)
					static_context:conditional_update(log_line,
						function() to_remove_set[key] = true end)
				end
			end
			local to_remove_indices = {}
			for i, value in ipairs(context.cur_array) do
				if to_remove_set[value[compare_key]] then
					table.insert(to_remove_indices, i)
				end
			end
			for i = #to_remove_indices, 1, -1 do
				table.remove(context.cur_array, to_remove_indices[i])
			end
		end
		return
	end
	local s = _get_value_set(context.cur_array)
	for _, value in ipairs(context.new_array) do
		if s[value] == nil then
			local log_line = string.format("%s: %s 'missing' -> '%s'.", static_context.name, context.path, value)
			static_context:conditional_update(log_line,
				function() table.insert(context.cur_array, value) end)
		end
	end

	local s = _get_value_set(context.new_array)
	local to_remove_indices = {}
	for i, value in ipairs(context.cur_array) do
		if s[value] == nil then
			local log_line = string.format("%s: %s '%s' -> 'removed'.", static_context.name, context.path, value)
			static_context:conditional_update(log_line, function() table.insert(to_remove_indices, i) end)
		end
	end
	for i = #to_remove_indices, 1, -1 do
		table.remove(context.cur_array, to_remove_indices[i])
	end
end

---@param context DictionaryContext
---@param static_context StaticContext
local function _transfer_dictionary(context, static_context)
	local keys = _get_sorted_keys(context.new_dictionary)
	for _, key in ipairs(keys) do
		local subpath = context.spec_path .. '.' .. key
		local cur_value = context.cur_dictionary[key]
		if cur_value == nil then
			local log_line = string.format("%s: %s.%s 'missing' -> '%s'.", static_context.name, context.path, key,
				_table_dump_simple(context.new_dictionary[key]))
			static_context:conditional_update(log_line,
				function() context.cur_dictionary[key] = context.new_dictionary[key] end)
		end
		---@type AnyContext
		local new_context = {
			new_data = context.new_dictionary[key],
			cur_data = cur_value,
			path = context.path ~= '' and (context.path .. '.' .. key) or key,
			spec_path = subpath
		}
		if _transfer_any(new_context, static_context) then
			context.cur_dictionary[key] = context.new_dictionary[key]
		end
	end
end

---@param context AnyContext
---@param static_context StaticContext
---@return boolean "Is additional transfer required from caller"
_transfer_any = function(context, static_context)
	if context.new_data == nil then
		return context.cur_data ~= nil
	end
	if context.cur_data == nil then
		return true
	end
	if type(context.new_data) ~= type(context.cur_data) then
		print(string.format("Unexpected type difference at '%s' for '%s'", context.spec_path, static_context.name))
		return false
	end
	local dtype = type(context.new_data)
	if dtype == "table" then
		if context.new_data[1] ~= nil then
			local cur_array = context.cur_data
			---@cast cur_array any[]
			local new_array = context.new_data
			---@cast new_array any[]
			---@type ArrayContext
			local array_context = {
				cur_array = cur_array,
				new_array = new_array,
				path = context.path,
				spec_path = context.spec_path,
			}
			_transfer_array(array_context, static_context)
			return false
		end
		local cur_dictionary = context.cur_data
		---@cast cur_dictionary {[any]: any}
		local new_dictionary = context.new_data
		---@cast new_dictionary {[any]: any}
		---@type DictionaryContext
		local dictionary_context = {
			cur_dictionary = cur_dictionary,
			new_dictionary = new_dictionary,
			path = context.path,
			spec_path = context.spec_path,
		}
		_transfer_dictionary(dictionary_context, static_context)
		return false
	end

	-- Transfer simple values, e.g. string or int
	if context.cur_data ~= context.new_data then
		local is_small_change = false
		local description = ''
		if type(context.cur_data) == "string" then
			local cur_str = context.cur_data
			---@cast cur_str string
			local new_str = context.new_data
			---@cast new_str string
			if cur_str:gsub("%s+", " "):gsub("’", "'"):gsub("_", "") == new_str:gsub("%s+", " "):gsub("’", "'"):gsub("_", "") then
				is_small_change = true
				description = " (White space only change)"
			end
		end
		if type(context.cur_data) == "number" then
			local cur_num = context.cur_data
			---@cast cur_num number
			local new_num = context.new_data
			---@cast new_num number
			---@type integer
			local percent = (new_num - cur_num) * 100 / cur_num
			if math.abs(percent) < 1.0 then
				is_small_change = true
			end
			description = string.format(" (%.1f%% change)", percent)
		end
		local log_line = string.format("%s: %s '%s' -> '%s'%s.",
			static_context.name, context.path, context.cur_data,
			context.new_data,
			description)
		return static_context:conditional_update(log_line, nil, is_small_change)
	end
	return false
end

---@type any
local parser = argparse("update-from-yaml", "Script for updating lua data from yaml/lua source")
parser:argument("source", "Source file lua or yaml")
parser:argument("current", "Target lua file")
parser:option("--spec", "Spec .yaml file")
parser:option("-o --output", "Output file", "out.lua")
parser:option("--transfer-type", "Transfer type (all/confirm/skip_small)", "skip_small")
---@type any
local args = parser:parse()

---@type {[string]: any}?
local src_tbl = nil
---@type string
local source_path = args.source
local src_ext = source_path:match("^.+(%..+)$")
if src_ext == '.yaml' then
	src_tbl = yaml.parse(io.open(source_path, 'r'):read("*all"))
elseif src_ext == '.lua' then
	src_tbl = dofile(source_path)
	if src_tbl == nil then
		error(string.format("Failed to parse '%s' file", source_path))
	end
else
	error(string.format("Unsupported extension '%s'. Supported: .yaml, .lua", src_ext))
end
---@type {[string]: any}
local cur_tbl = dofile(args.current)
---@type {[string]: SpecValue}
local spec_tbl = yaml.parse(io.open(args.spec, 'r'):read("*all"))
local key_list = _get_sorted_keys(src_tbl)
local static_context = StaticContext:new()
static_context.log = ''
---@type string
local transfer_type = args.transfer_type
static_context.transfer_type = transfer_type
static_context.spec_tbl = spec_tbl

for _, name in ipairs(key_list) do
	static_context.name = name
	---@type any
	local data = src_tbl[name]
	local cur_data = cur_tbl[name]
	if cur_data == nil then
		local log_line = string.format('"%s" full transfer.', name)
		local answer = 'y'
		if transfer_type == "confirm" then
			print(string.format(log_line .. " Update (y/n)?"))
			answer = io.read()
		end
		if answer == 'y' then
			static_context.log = static_context.log .. log_line .. '\n'
			cur_tbl[name] = data
		end
	else
		---@type AnyContext
		local context = {
			new_data = data,
			cur_data = cur_data,
			path = '',
			spec_path = 'root'
		}
		_transfer_any(context, static_context)
	end
end
---@type string
local dst_path = args.output
io.open(dst_path, 'w'):write(_table_dump(cur_tbl, spec_tbl))
print(string.format("Written output to '%s'", dst_path))
print('\nFull transfer log:\n')
print(static_context.log)
