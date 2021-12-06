defmodule Membrane.RTMP.Source do
  @moduledoc """
  Membrane Element being a server-side source of RTMP streams.

  Implementation based on FFmpeg
  """
  use Membrane.Source
  alias __MODULE__.Native
  alias Membrane.{AVC, Time, AAC, Buffer}
  require Membrane.Logger

  def_output_pad :audio,
    availability: :always,
    caps: Membrane.AAC.RemoteStream,
    mode: :pull

  def_output_pad :video,
    availability: :always,
    caps: {Membrane.H264.RemoteStream, stream_format: :byte_stream},
    mode: :pull

  def_options port: [
                spec: 1..65_535,
                description: "Port on which the server will listen"
              ],
              local_ip: [
                spec: binary(),
                default: "127.0.0.1",
                description:
                  "IP address on which the server will listen. This is useful if you have more than one network interface"
              ],
              timeout: [
                spec: Time.t() | :infinity,
                default: :infinity,
                description: """
                Time during which the connection with the client must be established before handle_prepared_to_playing fails.

                Duration given must be a multiply of one second or atom `:infinity`.
                """
              ]

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {:ok,
     %{
       timeout: opts.timeout,
       url: "rtmp://#{opts.local_ip}:#{opts.port}",
       provider: nil,
       stale_frame: nil
     }}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    # Native.create is blocking. Hence, the element will only go from prepared to playing when a new connection is established.
    # This might not be desirable, but unfortunately this is caused by the fact that FFmpeg's create_input_stream is awaiting a new connection from the client before returning.

    case Native.create(state.url, state.timeout) do
      {:ok, native} ->
        Membrane.Logger.debug("Connection established @ #{state.url}")
        my_pid = self()
        pid = spawn_link(fn -> frame_provider(native, my_pid) end)
        send(pid, :get_frame)
        {{:ok, get_params(native)}, %{state | provider: pid}}

      {:error, reason} ->
        raise("Transition to state `playing` failed. Reason: `#{reason}`")
    end
  end

  @impl true
  def handle_demand(type, _size, _unit, _ctx, %{stale_frame: {type, buffer}} = state) do
    # There is stale frame, which indicates that that the source was blocked waiting for demand from one of the outputs
    # It now arrived, so we request next frame and output the one that blocked us
    send(state.provider, :get_frame)
    {{:ok, buffer: {type, buffer}}, %{state | stale_frame: nil}}
  end

  @impl true
  def handle_demand(_type, _size, _unit, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_other({:frame_provider, {:ok, type, timestamp, frame}}, ctx, state)
      when ctx.playback_state == :playing do
    timestamp = Time.microseconds(timestamp)

    buffer = %Buffer{
      pts: timestamp,
      dts: timestamp,
      payload: prepare_payload(type, frame)
    }

    if get_in(ctx.pads, [type, :demand]) > 0 do
      send(state.provider, :get_frame)
      {{:ok, buffer: {type, buffer}}, state}
    else
      # if there is no demand for element of this type so we wait until it appears
      # effectively, it results in source adapting to the slower of the two outputs
      {:ok, %{state | stale_frame: {type, buffer}}}
    end
  end

  @impl true
  def handle_other({:frame_provider, :end_of_stream}, _ctx, state) do
    Membrane.Logger.debug("Received end of stream")
    {{:ok, end_of_stream: :audio, end_of_stream: :video}, state}
  end

  @impl true
  def handle_other({:frame_provider, {:error, reason}}, _ctx, _state),
    do: raise("Fetching of the frame failed. Reason: #{inspect(reason)}")

  defp frame_provider(native, target) do
    receive do
      :get_frame ->
        result = Native.read_frame(native)
        send(target, {:frame_provider, result})

        if result == :end_of_stream, do: :ok, else: frame_provider(native, target)

      :terminate ->
        :ok
    end
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    send(state.provider, :terminate)
    {:ok, state}
  end

  defp prepare_payload(:video, payload), do: AVC.Utils.to_annex_b(payload)
  defp prepare_payload(:audio, payload), do: payload

  defp get_params(native),
    do:
      [
        get_audio_params(native),
        get_video_params(native)
      ]
      |> Enum.concat()

  defp get_audio_params(native) do
    case Native.get_audio_params(native) do
      {:ok, audio_specific_config} ->
        caps = %Membrane.AAC.RemoteStream{
          audio_specific_config: audio_specific_config
        }

        [caps: {:audio, caps}]

      {:error, _reason} ->
        []
    end
  end

  defp get_video_params(native) do
    case Native.get_video_params(native) do
      {:ok, config} ->
        caps = %Membrane.H264.RemoteStream{
          decoder_configuration_record: config,
          stream_format: :byte_stream
        }

        [caps: {:video, caps}]

      {:error, _reason} ->
        []
    end
  end

  defp get_aac_caps(
         <<profile::5, sr_index::4, channel_configuration::4, frame_length_flag::1, _rest::bits>> =
           _audio_specific_config
       ),
       do:
         %AAC{
           profile: AAC.aot_id_to_profile(profile),
           mpeg_version: 4,
           sample_rate: AAC.sampling_frequency_id_to_sample_rate(sr_index),
           channels: AAC.channel_config_id_to_channels(channel_configuration),
           encapsulation: :none,
           samples_per_frame: if(frame_length_flag == 1, do: 1024, else: 960)
         }
         |> then(&{:ok, &1})

  defp get_aac_caps(_otherwise), do: {:error, :unknown_pattern}
end
