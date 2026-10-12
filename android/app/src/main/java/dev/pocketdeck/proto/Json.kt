package dev.pocketdeck.proto

/** Thrown for malformed JSON. */
class JsonException(message: String) : Exception(message)

/**
 * Minimal JSON encoder/parser.
 *
 * The protocol layer must run in plain-JVM unit tests where Android's `org.json`
 * is not available, so it carries its own implementation. Values are represented
 * with ordinary Kotlin types: `Map<String, Any?>` objects, `List<Any?>` arrays,
 * `String`, `Long`/`Double` numbers, `Boolean` and `null`.
 *
 * Only what the wire protocol needs is supported: no comments, no trailing
 * commas, no NaN/Infinity (encoded as `null`).
 */
object Json {

    fun encode(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.skipWs()
        val v = p.parseValue()
        p.skipWs()
        if (!p.eof()) throw JsonException("trailing input at ${p.pos}")
        return v
    }

    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?> =
        parse(text) as? Map<String, Any?> ?: throw JsonException("not a JSON object")

    @Suppress("UNCHECKED_CAST")
    fun asObject(value: Any?): Map<String, Any?>? = value as? Map<String, Any?>

    fun asList(value: Any?): List<Any?>? = value as? List<Any?>

    fun str(value: Any?): String? = value as? String

    fun int(value: Any?): Int? = (value as? Number)?.toInt()

    fun long(value: Any?): Long? = (value as? Number)?.toLong()

    fun bool(value: Any?): Boolean? = value as? Boolean

    private fun write(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> writeString(sb, value)
            is Boolean -> sb.append(if (value) "true" else "false")
            is Int -> sb.append(value)
            is Long -> sb.append(value)
            is Double -> sb.append(if (value.isFinite()) value.toString() else "null")
            is Float -> sb.append(if (value.isFinite()) value.toDouble().toString() else "null")
            is Number -> sb.append(value.toString())
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) sb.append(',')
                    first = false
                    writeString(sb, k.toString())
                    sb.append(':')
                    write(sb, v)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (v in value) {
                    if (!first) sb.append(',')
                    first = false
                    write(sb, v)
                }
                sb.append(']')
            }
            is Array<*> -> write(sb, value.toList())
            else -> writeString(sb, value.toString())
        }
    }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
    }

    private class Parser(private val s: String) {
        var pos = 0

        fun eof(): Boolean = pos >= s.length

        fun skipWs() {
            while (pos < s.length && s[pos].isWhitespace()) pos++
        }

        fun parseValue(): Any? {
            skipWs()
            if (eof()) throw JsonException("unexpected end of input")
            return when (val c = s[pos]) {
                '{' -> parseObject()
                '[' -> parseArray()
                '"' -> parseString()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c.isDigit()) parseNumber() else throw JsonException("unexpected '$c' at $pos")
            }
        }

        private fun <T> literal(text: String, value: T): T {
            if (!s.startsWith(text, pos)) throw JsonException("bad literal at $pos")
            pos += text.length
            return value
        }

        private fun parseObject(): Map<String, Any?> {
            expect('{')
            val map = LinkedHashMap<String, Any?>()
            skipWs()
            if (peek() == '}') { pos++; return map }
            while (true) {
                skipWs()
                if (peek() != '"') throw JsonException("expected key at $pos")
                val key = parseString()
                skipWs()
                expect(':')
                map[key] = parseValue()
                skipWs()
                when (val c = next()) {
                    ',' -> {}
                    '}' -> return map
                    else -> throw JsonException("expected ',' or '}' at ${pos - 1} (got '$c')")
                }
            }
        }

        private fun parseArray(): List<Any?> {
            expect('[')
            val list = ArrayList<Any?>()
            skipWs()
            if (peek() == ']') { pos++; return list }
            while (true) {
                list.add(parseValue())
                skipWs()
                when (val c = next()) {
                    ',' -> {}
                    ']' -> return list
                    else -> throw JsonException("expected ',' or ']' at ${pos - 1} (got '$c')")
                }
            }
        }

        private fun parseString(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                if (eof()) throw JsonException("unterminated string")
                when (val c = next()) {
                    '"' -> return sb.toString()
                    '\\' -> appendEscape(sb)
                    else -> {
                        if (c < ' ') throw JsonException("control character in string at ${pos - 1}")
                        sb.append(c)
                    }
                }
            }
        }

        private fun appendEscape(sb: StringBuilder) {
            if (eof()) throw JsonException("unterminated escape")
            when (val c = next()) {
                '"' -> sb.append('"')
                '\\' -> sb.append('\\')
                '/' -> sb.append('/')
                'b' -> sb.append('\b')
                'f' -> sb.append('\u000C')
                'n' -> sb.append('\n')
                'r' -> sb.append('\r')
                't' -> sb.append('\t')
                'u' -> {
                    val v = readHex4()
                    sb.append(v)
                    // A UTF-16 surrogate pair arrives as two \u escapes; append the
                    // low half so astral characters survive round-trips.
                    if (Character.isHighSurrogate(v) && pos + 1 < s.length && s[pos] == '\\' && s[pos + 1] == 'u') {
                        pos += 2
                        val low = readHex4()
                        if (Character.isLowSurrogate(low)) sb.append(low) else pos -= 2
                    }
                }
                else -> throw JsonException("bad escape '\\$c' at ${pos - 1}")
            }
        }

        private fun readHex4(): Char {
            var v = 0
            repeat(4) {
                if (eof()) throw JsonException("truncated \\u escape")
                val c = next()
                val d = when (c) {
                    in '0'..'9' -> c - '0'
                    in 'a'..'f' -> c - 'a' + 10
                    in 'A'..'F' -> c - 'A' + 10
                    else -> throw JsonException("bad hex '$c' at ${pos - 1}")
                }
                v = (v shl 4) or d
            }
            return v.toChar()
        }

        private fun parseNumber(): Any {
            val start = pos
            if (peek() == '-') pos++
            while (!eof() && s[pos].isDigit()) pos++
            var isDouble = false
            if (!eof() && s[pos] == '.') {
                isDouble = true
                pos++
                while (!eof() && s[pos].isDigit()) pos++
            }
            if (!eof() && (s[pos] == 'e' || s[pos] == 'E')) {
                isDouble = true
                pos++
                if (!eof() && (s[pos] == '+' || s[pos] == '-')) pos++
                while (!eof() && s[pos].isDigit()) pos++
            }
            val text = s.substring(start, pos)
            if (text.isEmpty() || text == "-") throw JsonException("bad number at $start")
            if (!isDouble) {
                text.toLongOrNull()?.let { return it }
            }
            return text.toDoubleOrNull() ?: throw JsonException("bad number '$text'")
        }

        private fun peek(): Char = if (eof()) '\u0000' else s[pos]

        private fun next(): Char {
            if (eof()) throw JsonException("unexpected end of input")
            return s[pos++]
        }

        private fun expect(c: Char) {
            if (eof() || s[pos] != c) throw JsonException("expected '$c' at $pos")
            pos++
        }
    }
}
