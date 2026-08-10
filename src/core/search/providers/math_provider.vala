using GLib;
using Gdk;

namespace Singularity {

    public class MathSearchProvider : GLib.Object, SearchProvider {
        public string id { get { return "math"; } }
        public string name { get { return "Calculator"; } }

        public MathSearchProvider() {
            Object();
        }

        public async List<SearchResult> search(string query, Cancellable? cancellable) throws Error {
            var results = new List<SearchResult>();

            string q = query.strip();
            string expression = q.has_suffix("=")
                ? q.substring(0, q.length - 1).strip() : q;
            // Only arithmetic expressions, and not a bare number on its own.
            var allowed = new Regex("""^[0-9\s\+\-\*\/\(\)\.]+$""");
            if (!allowed.match(expression)) return results;
            var only_digits = new Regex("""^[0-9\s\.]+$""");
            if (only_digits.match(expression)) return results;

            // Evaluate in-process: no python3 dependency, no per-keystroke
            // subprocess, and no exponentiation DoS (fork-free Math.pow).
            double value;
            if (!new ExprParser(expression).parse(out value)) return results;
            if (value != value) return results;                          // NaN
            if (value == double.INFINITY || value == -double.INFINITY) return results;

            string result = format_number(value);
            var res = new SearchResult(
                this,
                result,
                "Result of %s".printf(q),
                "accessories-calculator-symbolic"
            );
            res.score = 1000.0;
            res.activated.connect(() => {
                var clipboard = Display.get_default().get_clipboard();
                clipboard.set_text(result);
            });
            results.append(res);

            return results;
        }

        private static string format_number(double v) {
            if (v == Math.floor(v) && v.abs() < 1e15)
                return "%lld".printf((int64) v);
            return "%.10g".printf(v);
        }

        // Recursive-descent evaluator for + - * / ( ), unary +/-, decimals and
        // ** (right-associative power). Precedence: + - < * / < ** < unary.
        private class ExprParser {
            private string s;
            private int pos = 0;
            private bool ok = true;

            public ExprParser(string input) { s = input; }

            public bool parse(out double result) {
                result = 0;
                double v = expr();
                skip_ws();
                if (!ok || pos < s.length) return false;
                result = v;
                return true;
            }

            private void skip_ws() {
                while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t')) pos++;
            }

            private char peek() { return pos < s.length ? s[pos] : '\0'; }

            private double expr() {
                double v = term();
                while (ok) {
                    skip_ws();
                    char c = peek();
                    if (c == '+') { pos++; v += term(); }
                    else if (c == '-') { pos++; v -= term(); }
                    else break;
                }
                return v;
            }

            private double term() {
                double v = power();
                while (ok) {
                    skip_ws();
                    char c = peek();
                    if (c == '*' && !(pos + 1 < s.length && s[pos + 1] == '*')) {
                        pos++; v *= power();
                    } else if (c == '/') {
                        pos++;
                        double d = power();
                        if (d == 0) { ok = false; return 0; }
                        v /= d;
                    } else break;
                }
                return v;
            }

            private double power() {
                double b = unary();
                skip_ws();
                if (peek() == '*' && pos + 1 < s.length && s[pos + 1] == '*') {
                    pos += 2;
                    return Math.pow(b, power());   // right-associative
                }
                return b;
            }

            private double unary() {
                skip_ws();
                if (peek() == '-') { pos++; return -unary(); }
                if (peek() == '+') { pos++; return unary(); }
                return primary();
            }

            private double primary() {
                skip_ws();
                if (peek() == '(') {
                    pos++;
                    double v = expr();
                    skip_ws();
                    if (peek() == ')') pos++; else ok = false;
                    return v;
                }
                int start = pos;
                while (pos < s.length && ((s[pos] >= '0' && s[pos] <= '9') || s[pos] == '.')) pos++;
                if (pos == start) { ok = false; return 0; }
                return double.parse(s.substring(start, pos - start));
            }
        }
    }
}
