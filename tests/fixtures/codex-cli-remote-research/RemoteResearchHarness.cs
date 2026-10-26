// Offline research harness for docs/CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md.
// Synthetic data only: a loopback fake Responses provider, a token-authenticated
// WebSocket JSON-RPC client (the "Manager"), and a Windows ConPTY session that runs
// the REAL Codex CLI TUI. No network beyond 127.0.0.1, no real credentials, no paid calls.
// Not part of any production build; compiled at runtime by Invoke-RemoteResearch.ps1.
#nullable enable
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace CodexRemoteResearch
{
    public sealed class UpstreamRecord
    {
        public string Provider = "", Model = "", Thread = "", Kind = "";
        public int Items, ReasoningItems, EncryptedItems;
        public string[] Markers = Array.Empty<string>();
        public bool AuthMatch;
        public override string ToString() =>
            $"{Provider}/{Model} items={Items} reasoning={ReasoningItems} enc={EncryptedItems} thread=..{Thread} kind={Kind} markers=[{string.Join(",", Markers)}] auth={AuthMatch}";
    }

    /// <summary>Loopback-only fake Responses provider. Behaviour is selected by the request model.</summary>
    public sealed class FakeProvider : IDisposable
    {
        private readonly TcpListener _listener;
        private readonly string _token;
        private readonly CancellationTokenSource _cts = new();
        public readonly ConcurrentQueue<UpstreamRecord> Records = new();
        /// <summary>Models the test has marked as quota-exhausted (simulated usage limit from now on).</summary>
        public readonly ConcurrentDictionary<string, bool> Exhausted = new(StringComparer.Ordinal);
        public int Port { get; }

        public FakeProvider(string token)
        {
            _token = token;
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            Task.Run(AcceptLoop);
        }

        public List<UpstreamRecord> Snapshot() => Records.ToList();

        private async Task AcceptLoop()
        {
            while (!_cts.IsCancellationRequested)
            {
                TcpClient c;
                try { c = await _listener.AcceptTcpClientAsync(_cts.Token); } catch { return; }
                _ = Task.Run(() => Handle(c));
            }
        }

        private static string ReadLine(Stream s)
        {
            var sb = new StringBuilder();
            int b;
            while ((b = s.ReadByte()) >= 0) { if (b == '\n') break; if (b != '\r') sb.Append((char)b); }
            return sb.ToString();
        }

        private void Handle(TcpClient c)
        {
            using (c)
            {
                var s = c.GetStream();
                string requestLine = ReadLine(s);
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                string line;
                while ((line = ReadLine(s)).Length > 0)
                {
                    int i = line.IndexOf(':');
                    if (i > 0) headers[line[..i].Trim()] = line[(i + 1)..].Trim();
                }
                int len = headers.TryGetValue("content-length", out var l) ? int.Parse(l) : 0;
                var body = new byte[len]; int read = 0;
                while (read < len) { int n = s.Read(body, read, len - read); if (n <= 0) break; read += n; }
                string path = requestLine.Split(' ').ElementAtOrDefault(1) ?? "/";
                JsonNode? doc = null;
                try { doc = JsonNode.Parse(Encoding.UTF8.GetString(body)); } catch { }
                string model = doc?["model"]?.GetValue<string>() ?? "";
                var input = doc?["input"] as JsonArray ?? new JsonArray();
                string inputText = input.ToJsonString();
                string kind = "";
                if (headers.TryGetValue("x-codex-turn-metadata", out var meta))
                {
                    try { kind = JsonNode.Parse(meta)?["request_kind"]?.GetValue<string>() ?? ""; } catch { }
                }
                Records.Enqueue(new UpstreamRecord
                {
                    Provider = path.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "",
                    Model = model,
                    Items = input.Count,
                    ReasoningItems = input.Count(x => x?["type"]?.GetValue<string>() == "reasoning"),
                    EncryptedItems = input.Count(x => x is JsonObject o && o.ContainsKey("encrypted_content")),
                    Markers = Regex.Matches(inputText, @"MARK_[A-Za-z0-9_]+|\bmk[a-z0-9]+\b").Select(m => m.Value).Distinct().OrderBy(x => x).ToArray(),
                    Thread = headers.TryGetValue("thread-id", out var t) && t.Length >= 6 ? t[^6..] : "",
                    Kind = kind,
                    AuthMatch = headers.TryGetValue("authorization", out var a) && a == "Bearer " + _token,
                });
                Respond(s, model, Exhausted.ContainsKey(model));
            }
        }

        private static void Write(Stream s, int status, string reason, string contentType, byte[] payload, IDictionary<string, string>? extra = null)
        {
            var h = new StringBuilder();
            h.Append($"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n");
            if (extra != null) foreach (var kv in extra) h.Append($"{kv.Key}: {kv.Value}\r\n");
            h.Append("\r\n");
            var hb = Encoding.ASCII.GetBytes(h.ToString());
            s.Write(hb, 0, hb.Length); s.Write(payload, 0, payload.Length); s.Flush();
        }

        private static void Respond(Stream s, string model, bool exhausted)
        {
            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (exhausted || model.StartsWith("m-usage", StringComparison.Ordinal))
            {
                string json = "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"synthetic usage limit\",\"plan_type\":\"plus\",\"resets_at\":" + (now + 3600) + "}}";
                var hdr = new Dictionary<string, string>
                {
                    ["x-codex-primary-used-percent"] = "100",
                    ["x-codex-primary-window-minutes"] = "300",
                    ["x-codex-primary-reset-at"] = (now + 3600).ToString(),
                    ["x-codex-rate-limit-reached-type"] = "rate_limit_reached",
                };
                Write(s, 429, "Too Many Requests", "application/json", Encoding.UTF8.GetBytes(json), hdr);
                return;
            }
            string id = "resp_" + Guid.NewGuid().ToString("N")[..12];
            var events = new List<string>();
            void Ev(object o) { string j = JsonSerializer.Serialize(o); string type = JsonNode.Parse(j)!["type"]!.GetValue<string>(); events.Add($"event: {type}\ndata: {j}\n\n"); }
            Ev(new Dictionary<string, object> { ["type"] = "response.created", ["response"] = new Dictionary<string, object> { ["id"] = id } });
            if (model.EndsWith("-reason", StringComparison.Ordinal))
            {
                Ev(new Dictionary<string, object>
                {
                    ["type"] = "response.output_item.done", ["output_index"] = 0,
                    ["item"] = new Dictionary<string, object>
                    {
                        ["type"] = "reasoning", ["id"] = "rs_" + id,
                        ["summary"] = new[] { new Dictionary<string, object> { ["type"] = "summary_text", ["text"] = "synthetic summary" } },
                        ["encrypted_content"] = "SYNTHETIC_ENCRYPTED_BLOB",
                    },
                });
            }
            Ev(new Dictionary<string, object>
            {
                ["type"] = "response.output_item.done", ["output_index"] = 0,
                ["item"] = new Dictionary<string, object>
                {
                    ["type"] = "message", ["role"] = "assistant", ["id"] = "msg_" + id,
                    ["content"] = new[] { new Dictionary<string, object> { ["type"] = "output_text", ["text"] = "SYNTH_REPLY_FROM_" + model.Replace('-', '_').ToUpperInvariant() } },
                },
            });
            Ev(new Dictionary<string, object>
            {
                ["type"] = "response.completed",
                ["response"] = new Dictionary<string, object>
                {
                    ["id"] = id,
                    ["usage"] = new Dictionary<string, object?> { ["input_tokens"] = 1, ["input_tokens_details"] = null, ["output_tokens"] = 1, ["output_tokens_details"] = null, ["total_tokens"] = 2 },
                },
            });
            Write(s, 200, "OK", "text/event-stream", Encoding.UTF8.GetBytes(string.Concat(events)));
        }

        public void Dispose() { _cts.Cancel(); try { _listener.Stop(); } catch { } }
    }

    /// <summary>Token-authenticated WebSocket JSON-RPC client acting as the Manager.</summary>
    public sealed class WsRpcClient : IDisposable
    {
        private readonly ClientWebSocket _ws = new();
        private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode>> _pending = new();
        private readonly CancellationTokenSource _cts = new();
        private int _next;
        public readonly ConcurrentQueue<JsonNode> Notifications = new();
        public string HandshakeError = "";

        public static WsRpcClient? TryConnect(int port, string? token, int timeoutMs = 5000)
        {
            var c = new WsRpcClient();
            if (token != null) c._ws.Options.SetRequestHeader("Authorization", "Bearer " + token);
            try
            {
                using var t = new CancellationTokenSource(timeoutMs);
                c._ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), t.Token).GetAwaiter().GetResult();
            }
            catch (Exception e) { c.HandshakeError = e.GetBaseException().Message; return c; }
            Task.Run(c.ReceiveLoop);
            return c;
        }

        public bool Connected => _ws.State == WebSocketState.Open;

        private async Task ReceiveLoop()
        {
            var buf = new byte[1 << 16];
            var ms = new MemoryStream();
            while (!_cts.IsCancellationRequested && _ws.State == WebSocketState.Open)
            {
                WebSocketReceiveResult r;
                try { r = await _ws.ReceiveAsync(buf, _cts.Token); } catch { return; }
                if (r.MessageType == WebSocketMessageType.Close) return;
                ms.Write(buf, 0, r.Count);
                if (!r.EndOfMessage) continue;
                JsonNode? msg = null;
                try { msg = JsonNode.Parse(Encoding.UTF8.GetString(ms.ToArray())); } catch { }
                ms.SetLength(0);
                if (msg is null) continue;
                bool hasMethod = msg["method"] != null;
                if (!hasMethod && msg["id"] is JsonNode idNode && _pending.TryRemove(idNode.GetValue<int>(), out var tcs)) { tcs.TrySetResult(msg); continue; }
                if (hasMethod && msg["id"] != null)
                {
                    // Server-to-client approval request: always decline (no tool side effects).
                    var reply = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = msg["id"]!.DeepClone(), ["result"] = new JsonObject { ["decision"] = "decline" } };
                    _ = SendRaw(reply.ToJsonString());
                }
                if (hasMethod) Notifications.Enqueue(msg);
            }
        }

        private Task SendRaw(string s) => _ws.SendAsync(Encoding.UTF8.GetBytes(s), WebSocketMessageType.Text, true, _cts.Token);

        public JsonNode Request(string method, JsonNode? parameters, int timeoutMs = 30000)
        {
            int id = Interlocked.Increment(ref _next);
            var tcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pending[id] = tcs;
            var req = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters };
            SendRaw(req.ToJsonString()).GetAwaiter().GetResult();
            if (!tcs.Task.Wait(timeoutMs)) { _pending.TryRemove(id, out _); SoftTimeouts.Rpc.Enqueue("ws " + method); return new JsonObject { ["timeout"] = method }; }
            return tcs.Task.Result;
        }

        public void Notify(string method) => SendRaw(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = method }.ToJsonString()).GetAwaiter().GetResult();

        public JsonNode Initialize(string name)
        {
            var r = Request("initialize", JsonNode.Parse("{\"clientInfo\":{\"name\":\"" + name + "\",\"version\":\"0\"}}"));
            Notify("initialized");
            return r;
        }

        public List<JsonNode> Drain() { var l = new List<JsonNode>(); while (Notifications.TryDequeue(out var n)) l.Add(n); return l; }

        public void Dispose()
        {
            try { _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "done", CancellationToken.None).Wait(2000); } catch { }
            _cts.Cancel(); _ws.Dispose();
        }
    }

    /// <summary>
    /// One kill-on-close Windows Job Object per process the runner starts. Processes join by the
    /// HANDLE the runner holds (never by a PID lookup), so a reused PID can never be adopted; every
    /// descendant the process spawns afterwards is a job member automatically. Cleanup and network
    /// supervision use the job's own member list instead of guessing a process tree from parent PIDs.
    /// </summary>
    public sealed class ProcessGroup : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObjectW(IntPtr attrs, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, int size, out int returned);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);

        private IntPtr _job;
        public string Label { get; }

        public ProcessGroup(string label)
        {
            Label = label;
            _job = CreateJobObjectW(IntPtr.Zero, null);
            if (_job == IntPtr.Zero) throw new InvalidOperationException("CreateJobObject failed: " + Marshal.GetLastWin32Error());
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (no breakaway flags)
            if (!SetInformationJobObject(_job, 9, ref info, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
                throw new InvalidOperationException("SetInformationJobObject failed: " + Marshal.GetLastWin32Error());
        }

        /// <summary>Adds the process behind a handle the runner itself obtained when starting it.</summary>
        public void AssignHandle(IntPtr processHandle)
        {
            if (!AssignProcessToJobObject(_job, processHandle))
                throw new InvalidOperationException("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error());
        }

        /// <summary>Authoritative list of the job's current member process ids. Throws (fail closed)
        /// when the list cannot be obtained completely; a disposed job has no members.</summary>
        public int[] MemberPids()
        {
            if (_job == IntPtr.Zero) return Array.Empty<int>();
            for (int capacity = 64; capacity <= 65536; capacity *= 4)
            {
                int size = 8 + IntPtr.Size * capacity;
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    if (!QueryInformationJobObject(_job, 3, buf, size, out _))
                    {
                        int err = Marshal.GetLastWin32Error();
                        if (err == 234) continue; // ERROR_MORE_DATA: retry with a larger buffer
                        throw new InvalidOperationException($"QueryInformationJobObject({Label}) failed: {err}");
                    }
                    int assigned = Marshal.ReadInt32(buf, 0), count = Marshal.ReadInt32(buf, 4);
                    if (count < assigned) continue;
                    var pids = new int[count];
                    for (int i = 0; i < count; i++) pids[i] = (int)Marshal.ReadIntPtr(buf, 8 + i * IntPtr.Size);
                    return pids;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            throw new InvalidOperationException($"job member list of {Label} could not be read completely");
        }

        public int ActiveProcesses()
        {
            int size = Marshal.SizeOf<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>();
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (_job == IntPtr.Zero || !QueryInformationJobObject(_job, 1, buf, size, out _)) return -1;
                return (int)Marshal.PtrToStructure<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(buf).ActiveProcesses;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        /// <summary>Terminates every member and waits (bounded) until the job reports no active process.</summary>
        public bool TerminateAndWait(int timeoutMs)
        {
            if (_job == IntPtr.Zero) return true;
            TerminateJobObject(_job, 1);
            var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < end) { if (ActiveProcesses() == 0) return true; Thread.Sleep(100); }
            return ActiveProcesses() == 0;
        }

        public void Dispose()
        {
            if (_job == IntPtr.Zero) return;
            TerminateAndWait(5000);
            CloseHandle(_job);
            _job = IntPtr.Zero;
        }
    }

    /// <summary>TCP owner table (IPv4 + IPv6) via the documented GetExtendedTcpTable API.</summary>
    public static class TcpOwnerTable
    {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
        private const int TCP_TABLE_OWNER_PID_ALL = 5, AF_INET = 2, AF_INET6 = 23;
        private const uint MIB_TCP_STATE_LISTEN = 2;

        private static int Port(uint raw) => (int)(((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF));

        private static bool IsLocal(IPAddress a) =>
            IPAddress.IsLoopback(a) || a.Equals(IPAddress.Any) || a.Equals(IPAddress.IPv6Any) || a.Equals(IPAddress.IPv6None);

        /// <summary>Returns "pid->address:port" for every non-listening TCP connection of the given
        /// processes whose remote end is not loopback/unspecified. Throws (fail closed) whenever a
        /// table cannot be read completely; a failed read is never treated as "no connections".</summary>
        public static List<string> NonLoopback(ICollection<int> pids)
        {
            const uint ERROR_INSUFFICIENT_BUFFER = 122;
            var hits = new List<string>();
            if (pids.Count == 0) return hits;
            foreach (int af in new[] { AF_INET, AF_INET6 })
            {
                int size = 0;
                IntPtr buf = IntPtr.Zero;
                try
                {
                    for (int attempt = 0; ; attempt++)
                    {
                        uint rc = GetExtendedTcpTable(buf, ref size, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
                        if (rc == 0 && buf != IntPtr.Zero) break;
                        if (rc != ERROR_INSUFFICIENT_BUFFER || size <= 0 || attempt >= 4)
                            throw new InvalidOperationException($"GetExtendedTcpTable(af={af}) failed: {rc}");
                        if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf);
                        size += 4096; // the table can grow between the two calls
                        buf = Marshal.AllocHGlobal(size);
                    }
                    int n = Marshal.ReadInt32(buf);
                    int rowSize = af == AF_INET ? 24 : 56;
                    if (n < 0 || 4L + (long)n * rowSize > size) throw new InvalidOperationException($"GetExtendedTcpTable(af={af}) returned an inconsistent row count");
                    for (int i = 0; i < n; i++)
                    {
                        IntPtr row = buf + 4 + i * rowSize;
                        uint state, remotePort; int pid; IPAddress remote;
                        if (af == AF_INET)
                        {
                            state = (uint)Marshal.ReadInt32(row, 0);
                            remote = new IPAddress((long)(uint)Marshal.ReadInt32(row, 12));
                            remotePort = (uint)Marshal.ReadInt32(row, 16);
                            pid = Marshal.ReadInt32(row, 20);
                        }
                        else
                        {
                            var bytes = new byte[16];
                            Marshal.Copy(row + 24, bytes, 0, 16);
                            remote = new IPAddress(bytes);
                            remotePort = (uint)Marshal.ReadInt32(row, 44);
                            state = (uint)Marshal.ReadInt32(row, 48);
                            pid = Marshal.ReadInt32(row, 52);
                        }
                        if (state == MIB_TCP_STATE_LISTEN || !pids.Contains(pid) || IsLocal(remote)) continue;
                        hits.Add($"{pid}->{remote}:{Port(remotePort)}");
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            return hits;
        }
    }

    /// <summary>
    /// Run-level supervisor: every 500 ms it enforces the wall-clock budget and the loopback-only
    /// network rule over all registered process groups. On either breach it records the reason and
    /// terminates every group immediately (network circuit breaker / timeout).
    /// </summary>
    public sealed class Supervisor : IDisposable
    {
        private readonly List<ProcessGroup> _groups = new();
        private readonly object _gate = new();
        private Timer? _timer;
        private DateTime _deadline = DateTime.MaxValue;
        private volatile string _tripped = "";
        private volatile bool _stopping;
        private int _ticking;
        public string Tripped => _tripped;            // "", "TIMEOUT" or "NETWORK_VIOLATION"
        public readonly ConcurrentQueue<string> Violations = new();
        /// <summary>False when Dispose could not confirm that every timer callback had finished.</summary>
        public bool DrainedCleanly { get; private set; }

        /// <summary>Refuses new groups once tripped, so no process can start after a breach.</summary>
        public void Register(ProcessGroup group)
        {
            lock (_gate)
            {
                if (_tripped.Length > 0 || _stopping) throw new InvalidOperationException("supervisor no longer accepts processes: " + (_tripped.Length > 0 ? _tripped : "stopping"));
                _groups.Add(group);
            }
        }
        public void Unregister(ProcessGroup group) { lock (_gate) _groups.Remove(group); }

        public void Start(int budgetSeconds)
        {
            _deadline = DateTime.UtcNow.AddSeconds(budgetSeconds);
            _timer = new Timer(_ => Tick(), null, 500, 500);
        }

        public bool BudgetExceeded => DateTime.UtcNow > _deadline;

        /// <summary>Fail closed: if the job members or the TCP tables cannot be read, the failure is
        /// recorded as a violation and every group is terminated before the exception propagates.</summary>
        public List<string> ScanNow()
        {
            try
            {
                HashSet<int> pids;
                lock (_gate) pids = new HashSet<int>(_groups.SelectMany(g => g.MemberPids()));
                return TcpOwnerTable.NonLoopback(pids);
            }
            catch (Exception e)
            {
                Violations.Enqueue("monitor-failure: " + e.Message);
                Trip("NETWORK_VIOLATION");
                throw;
            }
        }

        private void Tick()
        {
            // Callbacks never overlap (a trip can take several seconds) and stop once Dispose begins.
            if (_stopping || Interlocked.Exchange(ref _ticking, 1) != 0) return;
            try
            {
                if (_tripped.Length > 0) { Trip(_tripped); return; }
                if (BudgetExceeded) { Trip("TIMEOUT"); return; }
                var hits = ScanNow();
                if (hits.Count > 0) { foreach (var h in hits) Violations.Enqueue(h); Trip("NETWORK_VIOLATION"); }
            }
            catch { /* ScanNow already recorded the monitor failure and tripped */ }
            finally { Volatile.Write(ref _ticking, 0); }
        }

        private void Trip(string reason)
        {
            lock (_gate)
            {
                // A network violation always wins; a timeout never overwrites an earlier reason.
                if (reason == "NETWORK_VIOLATION" || _tripped.Length == 0) _tripped = reason;
                foreach (var g in _groups) { try { g.TerminateAndWait(5000); } catch { } }
            }
        }

        public void Dispose()
        {
            _stopping = true;
            // Timer.Dispose() alone does not wait for a callback that is already running; DisposeAsync
            // completes only after all callback work has finished.
            bool drained = _timer == null || _timer.DisposeAsync().AsTask().Wait(60000);
            var spin = DateTime.UtcNow.AddSeconds(10);
            while (drained && Volatile.Read(ref _ticking) != 0 && DateTime.UtcNow < spin) Thread.Sleep(50);
            DrainedCleanly = drained && Volatile.Read(ref _ticking) == 0;
            // One last fail-closed scan of whatever is still running, then terminate everything.
            try { var hits = ScanNow(); if (hits.Count > 0) { foreach (var h in hits) Violations.Enqueue(h); Trip("NETWORK_VIOLATION"); } } catch { }
            lock (_gate)
            {
                foreach (var g in _groups) { try { g.Dispose(); } catch { } }
                _groups.Clear();
            }
        }
    }

    /// <summary>Soft timeouts inside the harness (an RPC request that got no reply in time). Any
    /// entry prevents the runner from reporting COMPLETED.</summary>
    public static class SoftTimeouts
    {
        public static readonly ConcurrentQueue<string> Rpc = new();
    }

    /// <summary>JSON-RPC over the app-server's default stdio transport (one private client).</summary>
    public sealed class StdioRpcClient : IDisposable
    {
        private readonly JobProcess _p;
        private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode>> _pending = new();
        private readonly object _writeGate = new();
        private int _next;
        public readonly ConcurrentQueue<JsonNode> Notifications = new();
        public int ProcessId => _p.Id;

        public StdioRpcClient(string exe, string workingDirectory, string stderrPath, ProcessGroup group)
        {
            // Started suspended and joined to its job before it runs (see JobProcess).
            _p = JobProcess.Start(exe, "app-server", workingDirectory, null, stderrPath, group);
            new Thread(ReadLoop) { IsBackground = true }.Start();
        }

        private void ReadLoop()
        {
            string? line;
            while ((line = _p.StandardOutput!.ReadLine()) != null)
            {
                JsonNode? msg = null;
                try { msg = JsonNode.Parse(line); } catch { }
                if (msg is null) continue;
                bool hasMethod = msg["method"] != null;
                if (!hasMethod && msg["id"] is JsonNode idNode && _pending.TryRemove(idNode.GetValue<int>(), out var tcs)) { tcs.TrySetResult(msg); continue; }
                if (hasMethod && msg["id"] != null)
                    SendRaw(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = msg["id"]!.DeepClone(), ["result"] = new JsonObject { ["decision"] = "decline" } }.ToJsonString());
                if (hasMethod) Notifications.Enqueue(msg);
            }
        }

        private void SendRaw(string s) { lock (_writeGate) { _p.StandardInput.WriteLine(s); _p.StandardInput.Flush(); } }

        public JsonNode Request(string method, JsonNode? parameters, int timeoutMs = 30000)
        {
            int id = Interlocked.Increment(ref _next);
            var tcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pending[id] = tcs;
            SendRaw(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters }.ToJsonString());
            if (!tcs.Task.Wait(timeoutMs)) { _pending.TryRemove(id, out _); SoftTimeouts.Rpc.Enqueue("stdio " + method); return new JsonObject { ["timeout"] = method }; }
            return tcs.Task.Result;
        }

        public JsonNode Initialize(string name)
        {
            var r = Request("initialize", JsonNode.Parse("{\"clientInfo\":{\"name\":\"" + name + "\",\"version\":\"0\"}}"));
            SendRaw(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "initialized" }.ToJsonString());
            return r;
        }

        public List<JsonNode> Drain() { var l = new List<JsonNode>(); while (Notifications.TryDequeue(out var n)) l.Add(n); return l; }

        /// <summary>Closes stdin (graceful shutdown request) and waits; terminates only this own child if it does not exit.</summary>
        public void Dispose()
        {
            try { _p.StandardInput.Close(); } catch { }
            if (!_p.WaitForExit(10000)) { try { _p.Terminate(); _p.WaitForExit(10000); } catch { } }
            _p.Dispose();
        }
    }

    /// <summary>
    /// Starts a console program CREATE_SUSPENDED, joins it to its kill-on-close job by the handle
    /// CreateProcess returned, and only then resumes it, so neither the program nor any child it
    /// spawns can run outside the job. Only the three std handles are inherited
    /// (PROC_THREAD_ATTRIBUTE_HANDLE_LIST). stdout goes to a new file, or to a pipe when no stdout
    /// path is given; stderr always goes to a new file; stdin is a pipe held open by the runner.
    /// </summary>
    public sealed class JobProcess : IDisposable
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO { public int cb; public string? lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
        [StructLayout(LayoutKind.Sequential)] private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
        [StructLayout(LayoutKind.Sequential)] private struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr a, int size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(SafeHandle h, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessW(string? app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string? cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr h, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);

        private const uint CREATE_SUSPENDED = 0x4, CREATE_UNICODE_ENVIRONMENT = 0x400, EXTENDED_STARTUPINFO_PRESENT = 0x80000, CREATE_NO_WINDOW = 0x08000000;
        private static readonly IntPtr HANDLE_LIST_ATTR = (IntPtr)0x00020002;

        private IntPtr _hProcess;
        public int Id { get; }
        public StreamWriter StandardInput { get; }
        public StreamReader? StandardOutput { get; }

        private JobProcess(IntPtr hProcess, int id, StreamWriter stdin, StreamReader? stdout)
        {
            _hProcess = hProcess; Id = id; StandardInput = stdin; StandardOutput = stdout;
        }

        public static JobProcess Start(string exe, string arguments, string workingDirectory, string? stdoutPath, string stderrPath, ProcessGroup group)
        {
            ArgumentNullException.ThrowIfNull(group);
            if (!CreatePipe(out var inRead, out var inWrite, IntPtr.Zero, 0)) throw new InvalidOperationException("CreatePipe failed: " + Marshal.GetLastWin32Error());
            SafeFileHandle? outRead = null, outWrite;
            FileStream? outFile = null;
            if (string.IsNullOrEmpty(stdoutPath)) // PowerShell passes $null as ""
            {
                if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new InvalidOperationException("CreatePipe failed: " + Marshal.GetLastWin32Error());
            }
            else { outFile = new FileStream(stdoutPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read); outWrite = outFile.SafeFileHandle; }
            var errFile = new FileStream(stderrPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            var childHandles = new SafeHandle[] { inRead, outWrite, errFile.SafeFileHandle };
            foreach (var h in childHandles)
                if (!SetHandleInformation(h, 1, 1)) throw new InvalidOperationException("SetHandleInformation failed: " + Marshal.GetLastWin32Error());

            IntPtr attrList = IntPtr.Zero, handleArray = IntPtr.Zero;
            PROCESS_INFORMATION pi;
            try
            {
                handleArray = Marshal.AllocHGlobal(IntPtr.Size * childHandles.Length);
                for (int i = 0; i < childHandles.Length; i++) Marshal.WriteIntPtr(handleArray, i * IntPtr.Size, childHandles[i].DangerousGetHandle());
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attrList = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref size)) { Marshal.FreeHGlobal(attrList); attrList = IntPtr.Zero; throw new InvalidOperationException("attr list"); }
                if (!UpdateProcThreadAttribute(attrList, 0, HANDLE_LIST_ATTR, handleArray, (IntPtr)(IntPtr.Size * childHandles.Length), IntPtr.Zero, IntPtr.Zero)) throw new InvalidOperationException("attr update");
                var si = new STARTUPINFOEX { lpAttributeList = attrList };
                si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
                si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
                si.StartupInfo.hStdInput = inRead.DangerousGetHandle();
                si.StartupInfo.hStdOutput = outWrite.DangerousGetHandle();
                si.StartupInfo.hStdError = errFile.SafeFileHandle.DangerousGetHandle();
                if (!CreateProcessW(null, new StringBuilder("\"" + exe + "\" " + arguments), IntPtr.Zero, IntPtr.Zero, true,
                        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, IntPtr.Zero, workingDirectory, ref si, out pi))
                    throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());
            }
            finally
            {
                if (attrList != IntPtr.Zero) { DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList); }
                if (handleArray != IntPtr.Zero) Marshal.FreeHGlobal(handleArray);
                // The child holds its own copies; the runner keeps only its pipe ends.
                inRead.Dispose(); errFile.Dispose();
                if (outFile != null) outFile.Dispose(); else outWrite.Dispose();
            }
            try
            {
                group.AssignHandle(pi.hProcess);
                if (ResumeThread(pi.hThread) == uint.MaxValue) throw new InvalidOperationException("ResumeThread failed: " + Marshal.GetLastWin32Error());
            }
            catch
            {
                TerminateProcess(pi.hProcess, 1); CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
                inWrite.Dispose(); outRead?.Dispose();
                throw;
            }
            CloseHandle(pi.hThread);
            var stdin = new StreamWriter(new FileStream(inWrite, FileAccess.Write), new UTF8Encoding(false));
            var stdout = outRead == null ? null : new StreamReader(new FileStream(outRead, FileAccess.Read), new UTF8Encoding(false));
            return new JobProcess(pi.hProcess, pi.dwProcessId, stdin, stdout);
        }

        public bool HasExited => WaitForSingleObject(_hProcess, 0) == 0;
        public bool WaitForExit(int ms) => WaitForSingleObject(_hProcess, (uint)ms) == 0;

        /// <summary>Terminates only this process (its job is terminated separately by the runner).</summary>
        public void Terminate() { if (!HasExited) TerminateProcess(_hProcess, 1); }

        public void Dispose()
        {
            try { StandardInput.Dispose(); } catch { }
            try { StandardOutput?.Dispose(); } catch { }
            if (_hProcess != IntPtr.Zero) { CloseHandle(_hProcess); _hProcess = IntPtr.Zero; }
        }
    }

    /// <summary>Runs a real console program inside a Windows pseudo console (ConPTY).</summary>
    public sealed class ConPtySession : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)] private struct COORD { public short X, Y; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO { public int cb; public string? lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
        [StructLayout(LayoutKind.Sequential)] private struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
        [StructLayout(LayoutKind.Sequential)] private struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr a, int size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr hpc);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern void ClosePseudoConsole(IntPtr hpc);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessW(string? app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string? cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr h, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr h, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);

        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private static readonly IntPtr PSEUDOCONSOLE_ATTR = (IntPtr)0x00020016;

        private IntPtr _hpc, _attrList;
        private PROCESS_INFORMATION _pi;
        private readonly FileStream _in, _out;
        private readonly StringBuilder _raw = new();
        private readonly object _gate = new();
        public int ProcessId => _pi.dwProcessId;

        public ConPtySession(string commandLine, string workingDirectory, ProcessGroup group, short cols = 140, short rows = 45)
        {
            ArgumentNullException.ThrowIfNull(group);
            CreatePipe(out var inRead, out var inWrite, IntPtr.Zero, 0);
            CreatePipe(out var outRead, out var outWrite, IntPtr.Zero, 0);
            int hr = CreatePseudoConsole(new COORD { X = cols, Y = rows }, inRead, outWrite, 0, out _hpc);
            if (hr != 0) throw new InvalidOperationException("CreatePseudoConsole failed: 0x" + hr.ToString("x"));
            inRead.Dispose(); outWrite.Dispose();
            _in = new FileStream(inWrite, FileAccess.Write);
            _out = new FileStream(outRead, FileAccess.Read);

            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            _attrList = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(_attrList, 1, 0, ref size)) throw new InvalidOperationException("attr list");
            if (!UpdateProcThreadAttribute(_attrList, 0, PSEUDOCONSOLE_ATTR, _hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new InvalidOperationException("attr update");
            var si = new STARTUPINFOEX { lpAttributeList = _attrList };
            si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            // When the parent's own stdio is redirected, the child would otherwise inherit
            // those handles instead of the pseudo console: force empty std handles.
            si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
            si.StartupInfo.hStdInput = IntPtr.Zero;
            si.StartupInfo.hStdOutput = IntPtr.Zero;
            si.StartupInfo.hStdError = IntPtr.Zero;
            // Start SUSPENDED, join the process group by the handle CreateProcess returned, and only then
            // resume: the TUI cannot start any child process outside the kill-on-close job.
            if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, workingDirectory, ref si, out _pi))
                throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());
            try { group.AssignHandle(_pi.hProcess); }
            catch { TerminateProcess(_pi.hProcess, 1); throw; }
            if (ResumeThread(_pi.hThread) == uint.MaxValue)
            {
                TerminateProcess(_pi.hProcess, 1);
                throw new InvalidOperationException("ResumeThread failed: " + Marshal.GetLastWin32Error());
            }
            new Thread(ReadLoop) { IsBackground = true }.Start();
        }

        private void ReadLoop()
        {
            var buf = new byte[8192];
            var dec = Encoding.UTF8.GetDecoder();
            var chars = new char[8192];
            try
            {
                int n;
                while ((n = _out.Read(buf, 0, buf.Length)) > 0)
                {
                    int c = dec.GetChars(buf, 0, n, chars, 0);
                    lock (_gate) _raw.Append(chars, 0, c);
                }
            }
            catch { }
        }

        public string Raw { get { lock (_gate) return _raw.ToString(); } }

        /// <summary>Visible text with VT/ANSI control sequences removed (good enough for text assertions).</summary>
        public string Plain => Regex.Replace(Regex.Replace(Raw, @"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", ""), @"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]|[\x00-\x08\x0b-\x1f]", "");

        public void Send(string text) { var b = Encoding.UTF8.GetBytes(text); _in.Write(b, 0, b.Length); _in.Flush(); }

        public void Type(string text, int perCharMs = 15) { foreach (char ch in text) { Send(ch.ToString()); Thread.Sleep(perCharMs); } }

        public bool WaitFor(string needle, int timeoutMs)
        {
            var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < end) { if (Plain.Contains(needle, StringComparison.Ordinal)) return true; Thread.Sleep(200); }
            return false;
        }

        public bool HasExited => WaitForSingleObject(_pi.hProcess, 0) == 0;
        public uint? ExitCode => HasExited && GetExitCodeProcess(_pi.hProcess, out var c) ? c : null;
        public bool WaitExit(int ms) => WaitForSingleObject(_pi.hProcess, (uint)ms) == 0;

        /// <summary>Terminates only the process this session started (a synthetic test TUI).</summary>
        public void TerminateOwnProcess() { if (!HasExited) TerminateProcess(_pi.hProcess, 1); }

        public void Dispose()
        {
            TerminateOwnProcess();
            // ClosePseudoConsole can block while console clients are still attached; bound it.
            var hpc = _hpc;
            var closer = Task.Run(() => { try { ClosePseudoConsole(hpc); } catch { } });
            closer.Wait(5000);
            try { _in.Dispose(); } catch { }
            try { _out.Dispose(); } catch { }
            if (_attrList != IntPtr.Zero) { DeleteProcThreadAttributeList(_attrList); Marshal.FreeHGlobal(_attrList); _attrList = IntPtr.Zero; }
            if (_pi.hProcess != IntPtr.Zero) CloseHandle(_pi.hProcess);
            if (_pi.hThread != IntPtr.Zero) CloseHandle(_pi.hThread);
        }
    }
}
