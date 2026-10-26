namespace Router.Configuration;

/// <summary>
/// Non-throwing publication boundary invoked by the config operator INSIDE the
/// mutation serialization gate immediately after a successful durable commit.
/// A running Host binds its <see cref="CurrentRouterState"/>; offline operator
/// instances leave the sink null.
/// </summary>
public interface IRouterConfigPublicationSink
{
    void Publish(PublishedRouterState state);
}
