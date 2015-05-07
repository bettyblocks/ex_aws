defmodule ExAws.KinesisTest do
  use ExUnit.Case, async: true

  test "#list_streams" do
    assert {:ok, %{"HasMoreStreams" => _, "StreamNames" => _}} = Test.Kinesis.list_streams
  end

  test "#list_streams with jsx and httpotion" do
    assert {:ok, %{"HasMoreStreams" => _, "StreamNames" => _}} = Test.KinesisAlt.list_streams
  end

end
