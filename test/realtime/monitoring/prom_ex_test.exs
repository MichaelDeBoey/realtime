defmodule Realtime.PromExTest do
  use ExUnit.Case, async: true
  doctest Realtime.PromEx
  alias Realtime.PromEx

  describe "get_metrics/0" do
    test "builds metrics in prometheus format which includes host region and id" do
      metrics = PromEx.get_metrics()

      assert String.contains?(
               metrics,
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."
             )

      assert String.contains?(metrics, "# TYPE beam_system_schedulers_online_info gauge")

      assert String.contains?(
               metrics,
               "beam_system_schedulers_online_info{host=\"nohost\",region=\"us-east-1\",id=\"nohost\"}"
             )
    end
  end

  describe "get_compressed_metrics/0" do
    test "builds metrics compressed using zlib" do
      compressed_metrics = PromEx.get_compressed_metrics()

      metrics = :zlib.uncompress(compressed_metrics)

      assert String.contains?(
               metrics,
               "# HELP beam_system_schedulers_online_info The number of scheduler threads that are online."
             )

      assert String.contains?(metrics, "# TYPE beam_system_schedulers_online_info gauge")

      assert String.contains?(
               metrics,
               "beam_system_schedulers_online_info{host=\"nohost\",region=\"us-east-1\",id=\"nohost\"}"
             )
    end
  end
end
