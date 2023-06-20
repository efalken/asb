import { B, cyellow, cblack } from "./Colors";
import { Radius } from "./Style";
import { Box, Flex } from "@rebass/grid";
import React from "react";

// eslint-disable-next-line
export default function ({
  size,
  width,
  weight,
  label,
  placeholder,
  ...props
}) {
  if (label !== undefined)
    return (
      <Flex
        {...props}
        style={{
          //border: `thin solid ${Gg}`,
          border: `yellow`,
          borderRadius: Radius,
          height: 30,
        }}
      >
        {/* This is the label */}
        <Flex
          alignItems="center"
          px="9px"
          style={{
            fontSize: size ? size : 14,
          }}
        >
          {label}
        </Flex>

        {/* This is the value */}
        <Box
          // style={{
          //   borderLeft: `thin solid ${Gg}`,
          // }}
          style={{
            backgroundColor: "black",
            borderRadius: "2px",
            cursor: "pointer",
            color: "yellow"
          }}
        >
          <input
            style={{
              border: "none",
              paddingLeft: 7,
              paddingRight: 7,
              outline: "none",
             // backgroundColor: "#fff",
              font: cblack,
              width: width ? width : 50,
              height: "100%",
              fontSize: size ? size : 18,
              fontWeight: weight ? weight : "normal",

            }}
          />
        </Box>
      </Flex>
    );
  else
    return (
      <Box {...props}>
        <input
          placeholder={placeholder}
          style={{
            border: `thin solid ${cyellow}`,
            width: width ? width : 120,
            color: "cyellow",
            outline: "none",
            backgroundColor: cblack,
            padding: "5px 7px 5px 7px",
            fontSize: size ? size : 14,
            fontWeight: weight ? weight : "normal",
            borderRadius: Radius,
          }}
        />
      </Box>
    );
}