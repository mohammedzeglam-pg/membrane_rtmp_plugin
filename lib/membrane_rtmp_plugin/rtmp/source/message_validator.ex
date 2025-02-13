defprotocol Membrane.RTMP.MessageValidator do
  alias Membrane.RTMP.Messages

  @moduledoc """
  Protocol for implementing RTMP Message validators. Allows for verifying some
  of the RTMP messages.
  """

  @type validation_result_t :: {:ok, term()} | {:error, reason :: any()}

  @doc """
  Validates the `t:Membrane.RTMP.Messages.ReleaseStream.t/0` message.
  """
  @spec validate_release_stream(t(), Messages.ReleaseStream.t()) :: validation_result_t()
  def validate_release_stream(impl, message)

  @doc """
  Validates the `t:Membrane.RTMP.Messages.Publish.t/0` message.
  """
  @spec validate_publish(t(), Messages.Publish.t()) :: validation_result_t()
  def validate_publish(impl, message)

  @doc """
  Validates the `t:Membrane.RTMP.Messages.SetDataFrame.t/0` message.
  """
  @spec validate_set_data_frame(t(), Messages.SetDataFrame.t()) :: validation_result_t()
  def validate_set_data_frame(impl, message)
end
