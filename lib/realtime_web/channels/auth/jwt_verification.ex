defmodule RealtimeWeb.JwtVerification do
  @moduledoc """
  Parse JWT and verify claims
  """
  # Matching error in Dialyzer when using Joken.peek_claims/1 but {:ok, []} is actually possible and covered by our testing
  @dialyzer {:nowarn_function, check_claims_format: 1}

  defmodule JwtAuthToken do
    @moduledoc false
    use Joken.Config

    @impl true
    def token_config do
      Application.fetch_env!(:realtime, :jwt_claim_validators)
      |> Enum.reduce(%{}, fn {claim_key, expected_val}, claims ->
        add_claim_validator(claims, claim_key, expected_val)
      end)
      |> add_claim_validator("exp")
    end

    defp add_claim_validator(claims, "exp") do
      current_time = current_time()
      add_claim(claims, "exp", nil, &(&1 > current_time), message: current_time)
    end

    defp add_claim_validator(claims, claim_key, expected_val) do
      add_claim(claims, claim_key, nil, &(&1 == expected_val))
    end
  end

  @hs_algorithms ["HS256", "HS384", "HS512"]
  @rs_algorithms ["RS256", "RS384", "RS512"]
  @es_algorithms ["ES256", "ES384", "ES512"]
  @ed_algorithms ["Ed25519", "Ed448"]

  @doc """
  Verify JWT token and validate claims
  """
  @spec verify(binary(), binary(), binary() | nil) :: {:ok, map()} | {:error, any()}
  def verify(token, jwt_secret, jwt_jwks) when is_binary(token) do
    with {:ok, _claims} <- check_claims_format(token),
         {:ok, header} <- check_header_format(token),
         {:ok, signer} <- generate_signer(header, jwt_secret, jwt_jwks) do
      JwtAuthToken.verify_and_validate(token, signer)
    else
      {:error, _e} = error -> error
    end
  end

  def verify(_token, _jwt_secret, _jwt_jwks), do: {:error, :not_a_string}

  defp check_claims_format(token) do
    case Joken.peek_claims(token) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, _} -> {:error, :expected_claims_map}
      {:error, :token_malformed} -> {:error, :token_malformed}
    end
  end

  defp check_header_format(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _error -> {:error, :expected_header_map}
    end
  end

  defp generate_signer(%{"typ" => "JWT", "alg" => alg, "kid" => kid}, _jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @rs_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "RSA" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  defp generate_signer(%{"typ" => "JWT", "alg" => alg, "kid" => kid}, _jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @es_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "EC" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  defp generate_signer(%{"typ" => "JWT", "alg" => alg, "kid" => kid}, _jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @ed_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "OKP" and jwk["kid"] == kid end)

    case jwk do
      nil -> {:error, :error_generating_signer}
      _ -> {:ok, Joken.Signer.create(alg, jwk)}
    end
  end

  # Most Supabase Auth JWTs fall in this case, as they're usually signed with
  # HS256, have a kid header, but there's no JWK as this is sensitive. In this
  # case, the jwt_secret should be used.
  defp generate_signer(%{"typ" => "JWT", "alg" => alg, "kid" => kid}, jwt_secret, %{
         "keys" => keys
       })
       when is_binary(kid) and alg in @hs_algorithms do
    jwk = Enum.find(keys, fn jwk -> jwk["kty"] == "oct" and jwk["kid"] == kid and is_binary(jwk["k"]) end)

    if jwk do
      case Base.url_decode64(jwk["k"], padding: false) do
        {:ok, secret} -> {:ok, Joken.Signer.create(alg, secret)}
        _ -> {:error, :error_generating_signer}
      end
    else
      # If there's no JWK, and HS* is being used, instead of erroring, try
      # the jwt_secret instead.
      {:ok, Joken.Signer.create(alg, jwt_secret)}
    end
  end

  defp generate_signer(%{"typ" => "JWT", "alg" => alg}, jwt_secret, _jwt_jwks)
       when alg in @hs_algorithms do
    {:ok, Joken.Signer.create(alg, jwt_secret)}
  end

  defp generate_signer(_header, _jwt_secret, _jwt_jwks), do: {:error, :error_generating_signer}
end
