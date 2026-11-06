# Load the same config Mix uses without including Mix/compiler startup in samples.
Application.put_all_env(Config.Reader.read!("config/config.exs", env: :dev))
Code.require_file("demo.exs")
