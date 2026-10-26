namespace Router.Metering;

/// <summary>
/// Thread-safe bounded in-memory metering store. Capacity is a hard ceiling;
/// records are keyed by request id so one logical request can never produce
/// duplicate metering records.
/// </summary>
public sealed class RequestMeteringStore
{
    public const int DefaultCapacity = 500;
    public const int MaxCapacity = 1000;

    private readonly object _sync = new();
    private readonly Dictionary<string, RequestMeteringRecord> _records = new(StringComparer.Ordinal);
    private readonly Queue<string> _order = new();
    private readonly int _capacity;

    public RequestMeteringStore(int capacity = DefaultCapacity)
    {
        _capacity = Math.Clamp(capacity, 1, MaxCapacity);
    }

    public int Count
    {
        get
        {
            lock (_sync)
            {
                return _records.Count;
            }
        }
    }

    public int Capacity => _capacity;

    public void Add(RequestMeteringRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        lock (_sync)
        {
            if (_records.ContainsKey(record.RequestId))
            {
                // Idempotent replace: a re-delivered completion for the same
                // logical request must never be double counted.
                _records[record.RequestId] = record;
                return;
            }

            _records.Add(record.RequestId, record);
            _order.Enqueue(record.RequestId);
            while (_records.Count > _capacity && _order.Count > 0)
            {
                string oldest = _order.Dequeue();
                _records.Remove(oldest);
            }
        }
    }

    public IReadOnlyList<RequestMeteringRecord> Recent(int maxCount = 20)
    {
        int limit = Math.Clamp(maxCount, 1, _capacity);
        lock (_sync)
        {
            List<RequestMeteringRecord> records = new(_order.Count);
            foreach (string requestId in _order)
            {
                if (_records.TryGetValue(requestId, out RequestMeteringRecord? record))
                {
                    records.Add(record);
                }
            }

            if (records.Count <= limit)
            {
                return records;
            }

            return records.GetRange(records.Count - limit, limit);
        }
    }
}
