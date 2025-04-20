# Almost a zip library

AZL implements small but usable subset of `.zip` spec.

## Limitations

In particular: no Zip64, no encryption, only deflate / store compression methods, no non-seekable streams support.

Aslo following assumption been made: ``End of central directory`` is located right at the end of the file. 
(true for most wild files but not required by the spec)
