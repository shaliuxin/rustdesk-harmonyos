//! OpenHarmony shim for `tokio-native-tls`, implemented on top of `tokio-rustls`.
//!
//! 目标：让 `hbb_common` 的 `use tokio_native_tls::{native_tls, TlsConnector, TlsStream}`
//! 在 OpenHarmony 上编译通过，同时不引入 `native-tls` -> `openssl-sys` 这条 C 依赖链。
//!
//! 只实现上游用到的 API 子集：
//!   - `native_tls::TlsConnector::builder()` / `TlsConnectorBuilder::danger_accept_invalid_certs()` / `build()`
//!   - `native_tls::Error`
//!   - `TlsConnector::from(native_tls::TlsConnector)`
//!   - `TlsConnector::connect(domain, stream)`
//!   - `TlsStream<S>`：AsyncRead + AsyncWrite
//!
//! 未实现（上游未使用）：`Identity` / `Certificate` / 客户端证书 / ALPN 显式设置。

use std::fmt;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_rustls::TlsConnector as RustlsConnector;

/// 与真实 `native_tls` 模块路径对齐：`tokio_native_tls::native_tls::*`
pub mod native_tls {
    use std::fmt;
    use std::sync::Arc;

    use tokio_rustls::rustls;

    /// 与 `native_tls::Error` 同形的错误类型（thiserror 的 `#[from]` 需要 Display + Error）。
    #[derive(Debug)]
    pub struct Error(pub String);

    impl Error {
        pub(crate) fn new(msg: impl Into<String>) -> Self {
            Self(msg.into())
        }
    }

    impl fmt::Display for Error {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(&self.0)
        }
    }

    impl std::error::Error for Error {}

    impl From<rustls::Error> for Error {
        fn from(e: rustls::Error) -> Self {
            Self(format!("rustls: {e}"))
        }
    }

    impl From<rustls::pki_types::InvalidDnsNameError> for Error {
        fn from(e: rustls::pki_types::InvalidDnsNameError) -> Self {
            Self(format!("invalid dns name: {e}"))
        }
    }

    /// 证书校验器：接受任意证书（对应 `danger_accept_invalid_certs(true)`）。
    #[derive(Debug)]
    struct NoVerifier;

    impl rustls::client::danger::ServerCertVerifier for NoVerifier {
        fn verify_server_cert(
            &self,
            _end_entity: &rustls::pki_types::CertificateDer<'_>,
            _intermediates: &[rustls::pki_types::CertificateDer<'_>],
            _server_name: &rustls::pki_types::ServerName<'_>,
            _ocsp_response: &[u8],
            _now: rustls::pki_types::UnixTime,
        ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &rustls::pki_types::CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            // 关闭校验的场景下不限制签名算法，交给对端协商。
            vec![
                rustls::SignatureScheme::RSA_PKCS1_SHA256,
                rustls::SignatureScheme::RSA_PKCS1_SHA384,
                rustls::SignatureScheme::RSA_PKCS1_SHA512,
                rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
                rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
                rustls::SignatureScheme::RSA_PSS_SHA256,
                rustls::SignatureScheme::RSA_PSS_SHA384,
                rustls::SignatureScheme::RSA_PSS_SHA512,
                rustls::SignatureScheme::ED25519,
            ]
        }
    }

    /// 与 `native_tls::TlsConnector` 对应（此处只保存配置，真正的握手在 tokio 包装层）。
    #[derive(Clone)]
    pub struct TlsConnector {
        pub(crate) danger_accept_invalid_certs: bool,
    }

    impl fmt::Debug for TlsConnector {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.debug_struct("TlsConnector")
                .field(
                    "danger_accept_invalid_certs",
                    &self.danger_accept_invalid_certs,
                )
                .finish()
        }
    }

    impl TlsConnector {
        pub fn builder() -> TlsConnectorBuilder {
            TlsConnectorBuilder {
                danger_accept_invalid_certs: false,
            }
        }

        pub(crate) fn client_config(&self) -> Arc<rustls::ClientConfig> {
            let config = if self.danger_accept_invalid_certs {
                rustls::ClientConfig::builder()
                    .dangerous()
                    .with_custom_certificate_verifier(Arc::new(NoVerifier))
                    .with_no_client_auth()
            } else {
                let mut roots = rustls::RootCertStore::empty();
                roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
                rustls::ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth()
            };
            Arc::new(config)
        }
    }

    /// 与 `native_tls::TlsConnectorBuilder` 对应。
    #[derive(Default)]
    pub struct TlsConnectorBuilder {
        danger_accept_invalid_certs: bool,
    }

    impl TlsConnectorBuilder {
        pub fn danger_accept_invalid_certs(&mut self, danger: bool) -> &mut Self {
            self.danger_accept_invalid_certs = danger;
            self
        }

        pub fn build(&self) -> Result<TlsConnector, Error> {
            Ok(TlsConnector {
                danger_accept_invalid_certs: self.danger_accept_invalid_certs,
            })
        }
    }
}

/// 异步 TLS 连接器：`tokio_native_tls::TlsConnector`
#[derive(Clone)]
pub struct TlsConnector(RustlsConnector);

impl fmt::Debug for TlsConnector {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TlsConnector")
    }
}

impl From<native_tls::TlsConnector> for TlsConnector {
    fn from(c: native_tls::TlsConnector) -> Self {
        Self(RustlsConnector::from(c.client_config()))
    }
}

impl TlsConnector {
    /// 与 `tokio_native_tls::TlsConnector::connect` 同签名。
    pub async fn connect<S>(
        &self,
        domain: &str,
        stream: S,
    ) -> Result<TlsStream<S>, native_tls::Error>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let server_name = rustls_pki_types::ServerName::try_from(domain.to_owned())
            .map_err(native_tls::Error::from)?;
        let stream = self
            .0
            .connect(server_name, stream)
            .await
            .map_err(|e| native_tls::Error::new(format!("tls handshake failed: {e}")))?;
        Ok(TlsStream(stream))
    }
}

/// 与 `tokio_native_tls::TlsStream` 对应。
pub struct TlsStream<S>(tokio_rustls::client::TlsStream<S>);

impl<S> fmt::Debug for TlsStream<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TlsStream")
    }
}

impl<S> Unpin for TlsStream<S> {}

impl<S> AsyncRead for TlsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_read(cx, buf)
    }
}

impl<S> AsyncWrite for TlsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().0).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_shutdown(cx)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().0).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.0.is_write_vectored()
    }
}
